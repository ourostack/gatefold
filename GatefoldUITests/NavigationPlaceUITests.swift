import XCTest
import UIKit

/// Every way of moving that isn't a page turn keeps the place: he jumps, leaves without turning, and
/// the book reopens where he jumped to. Build 17 lost a move reported while the iPad's first layout
/// was still settling (it reopened at the start, then landed on the Cloud's older place).
@MainActor
final class NavigationPlaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The iPad on its side lays out a spread after a portrait first layout: the reflow that held the move.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    private func waitForWords(changingFrom old: String? = nil, timeout: TimeInterval = 60) -> String {
        let up = Date().addingTimeInterval(timeout)
        while Date() < up {
            let now = visibleText
            if !now.isEmpty, now != old { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return visibleText
    }

    /// The words that open the page: a spread's right page can still be drawing when it is read.
    private func opening(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
    }

    private func openFresh(_ extra: [String] = []) -> String {
        app.launchArguments = common + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 60))
        return waitForWords()
    }

    private func showChrome() {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 5))
    }

    /// Leaves without a turn and comes back: the reopen shows `words`.
    private func leaveAndReturn(expecting words: String, _ how: String) {
        sleep(2)
        let settled = visibleText
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        sleep(3)
        app.terminate()
        app.launchArguments = common
        app.launch()
        _ = waitForWords()
        sleep(4)
        XCTAssertEqual(opening(visibleText), opening(settled), "after a \(how) and no turn, the reopen is on the page he jumped to")
        XCTAssertNotEqual(opening(settled), opening(words), "the \(how) moved the page")
    }

    func testAContentsJumpKeepsThePlace() {
        let first = openFresh()
        showChrome()
        app.buttons["reader.contents"].tap()
        // The list is lazy: chapter XXX is only built once it scrolls into view.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10),
                      "the contents opened")
        for _ in 0..<20 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists && row.isHittable, "the contents list chapter XXX")
        row.tap()
        _ = waitForWords(changingFrom: first, timeout: 20)
        leaveAndReturn(expecting: first, "contents jump")
    }

    func testAScrubberJumpKeepsThePlace() {
        let first = openFresh()
        showChrome()
        let scrubber = app.descendants(matching: .any)["reader.scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)).tap()
        _ = waitForWords(changingFrom: first, timeout: 20)
        leaveAndReturn(expecting: first, "scrubber jump")
    }

    private func turn(forward: Bool) {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.92 : 0.08, dy: 0.5)).tap()
    }

    private func leaveAndRelaunch() {
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        sleep(3)
        app.terminate()
        app.launchArguments = common + relaunchExtra
        app.launch()
    }

    private var relaunchExtra: [String] = []

    /// The review's path on the iPad spread: his place is saved (a turn there and back), he closes the
    /// book, opens it from the shelf, and leaves twice without turning. Build 17 reopened chapter X,
    /// then XI, from chapter XIX.
    func testOpenedFromTheShelfThenLeftTwiceWithoutATurnKeepsThePlace() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        let first = waitForWords()
        sleep(3)
        turn(forward: true)
        _ = waitForWords(changingFrom: first, timeout: 10)
        sleep(2)
        turn(forward: false)
        sleep(3)
        let saved = opening(visibleText)
        XCTAssertFalse(saved.isEmpty)

        showChrome()
        app.buttons["reader.close"].firstMatch.tap()
        let cover = app.descendants(matching: .any)["book.gutenberg-pride-and-prejudice"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 15), "back on the shelf")
        sleep(2)
        app.terminate()
        app.launchArguments = common
        app.launch()
        XCTAssertTrue(cover.waitForExistence(timeout: 30), "the shelf after a relaunch")
        cover.tap()
        _ = waitForWords()
        sleep(4)
        XCTAssertEqual(opening(visibleText), saved, "opened from the shelf on his saved page")

        for round in 1...2 {
            leaveAndRelaunch()
            _ = waitForWords()
            sleep(5)
            XCTAssertEqual(opening(visibleText), saved, "reopen \(round) after leaving without a turn is on his page")
        }
    }

    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The review's rotation path: a Contents jump, two pages read in portrait, a turn to landscape and
    /// out without a turn. Build 17 reopened a page early each time (his first line on the right-hand
    /// page, the saved place rewritten to the spread's left edge). A layout change never moves the place:
    /// every reopen shows his first words, however many times he leaves.
    func testReadInPortraitRotatedThenLeftKeepsHisFirstWords() throws {
        try rotateThenLeave(furniture: false)
    }

    /// The same with page numbers on, as he reads: the count runs while he reads and rotates.
    func testWithPageNumbersOnReadInPortraitRotatedThenLeftKeepsHisFirstWords() throws {
        try rotateThenLeave(furniture: true)
    }

    private func rotateThenLeave(furniture: Bool) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        XCUIDevice.shared.orientation = .portrait
        relaunchExtra = furniture ? ["-GatefoldPageFurniture", "YES"] : []
        let first = openFresh(relaunchExtra)
        showChrome()
        app.buttons["reader.contents"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<20 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        row.tap()
        var words = waitForWords(changingFrom: first, timeout: 20)
        sleep(3)
        for _ in 0..<2 {
            turn(forward: true)
            words = waitForWords(changingFrom: words, timeout: 10)
            sleep(2)
        }
        let his = opening(visibleText)
        XCTAssertFalse(his.isEmpty)

        XCUIDevice.shared.orientation = .landscapeLeft
        // He stays a while on the new spread: long enough for the page count to finish behind it.
        sleep(45)
        XCTAssertTrue(flat(visibleText).contains(his), "the spread shows his first words")
        let spread = opening(visibleText)
        for round in 1...3 {
            leaveAndRelaunch()
            _ = waitForWords()
            sleep(6)
            XCTAssertTrue(flat(visibleText).contains(his), "reopen \(round) after a rotation and no turn shows his first words")
            XCTAssertEqual(opening(visibleText), spread, "reopen \(round) is the spread he left, not one a page early")
        }
    }
}
