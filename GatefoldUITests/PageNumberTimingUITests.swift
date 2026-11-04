import XCTest

/// A page number comes up within moments of the page, wherever the book opens. Build 17 counted every
/// chapter from the first, one at a time and only after a fixed wait, so deep in a book no number
/// showed for minutes; a reopen before the count was done started it over (the reviewer's chain at
/// 0.12 and 0.47 never showed one).
@MainActor
final class PageNumberTimingUITests: XCTestCase {
    private var app: XCUIApplication!

    /// From the page showing to its number, as the test sees it (each look at the screen takes a
    /// few tenths of a second; the app logs its own time, "pages: first number after").
    private let budget: TimeInterval = 3

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldPageFurniture", "YES",
    ]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    private var hasNumber: Bool {
        app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex
            .contains { Int($0.label) != nil }
    }

    /// Seconds from the page showing its words to a number on it; nil if none came within a minute.
    private func secondsToNumber() -> TimeInterval? {
        let up = Date().addingTimeInterval(90)
        while visibleText.isEmpty, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(visibleText.isEmpty, "the page never showed")
        let shown = Date()
        while Date().timeIntervalSince(shown) < 60 {
            if hasNumber { return Date().timeIntervalSince(shown) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func open(_ book: String, at spot: String, reset: Bool) {
        app.launchArguments = common + (reset ? ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES"] : [])
            + ["-GatefoldOpenBook", book, "-GatefoldGoTo", spot]
        app.launch()
    }

    private func check(_ book: String, _ spot: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let seconds = secondsToNumber()
        print("number timing: \(book) at \(spot), \(what): \(seconds.map { String(format: "%.1f", $0) } ?? "none") s")
        XCTAssertNotNil(seconds, "\(book) at \(spot), \(what): no page number within a minute", file: file, line: line)
        if let seconds {
            XCTAssertLessThan(seconds, budget, "\(book) at \(spot), \(what): the number took \(seconds) s", file: file, line: line)
        }
    }

    /// A fresh book, opened at three places: the number is up within moments each time.
    func testANumberComesUpWithinMomentsOfAFreshOpen() {
        let books = ProcessInfo.processInfo.environment["GATEFOLD_TIMING_BOOKS"]?.split(separator: ",").map(String.init)
            ?? ["gutenberg-pride-and-prejudice"]
        for book in books {
            for spot in ["0.12", "0.31", "0.47"] {
                open(book, at: spot, reset: true)
                check(book, spot, "fresh open")
            }
        }
    }

    /// Opened from a reset and closed at once, before the book could be counted, then reopened: the
    /// reopen's number comes up within moments of its picture lifting.
    func testANumberComesUpWithinMomentsOfAReopenAfterAnUnfinishedCount() {
        for spot in ["0.12", "0.47"] {
            open("gutenberg-pride-and-prejudice", at: spot, reset: true)
            let up = Date().addingTimeInterval(90)
            while visibleText.isEmpty, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            // Leave the way he would (the place and its picture are kept), then come back.
            XCUIDevice.shared.press(.home)
            if !app.wait(for: .runningBackground, timeout: 3) {
                XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
            }
            sleep(2)
            app.terminate()
            app.launchArguments = common
            app.launch()
            check("gutenberg-pride-and-prejudice", spot, "reopen")
        }
    }
}
