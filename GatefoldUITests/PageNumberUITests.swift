import XCTest

/// Page numbers are the pages he sees, as in Apple Books: every turn moves on one page (two on a
/// spread), a spread's two numbers are consecutive, and a reopen shows the same numbers. Build 16's
/// came from Readium's positions: ten turns on the folded Duo read 101 ×4, 102 ×3, 103 ×3, and the
/// iPad's spreads read 101/102, 101/102, 102/103…
@MainActor
final class PageNumberUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    /// The numbers on the pages in view, left to right.
    private var numbers: [Int] {
        app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { Int($0.label) }
    }

    /// The numbers once they have stopped changing for `quiet` seconds (the book is counted behind
    /// the page, so the first can take a while).
    private func settledNumbers(timeout: TimeInterval, quiet: TimeInterval = 1.5) -> [Int] {
        let deadline = Date().addingTimeInterval(timeout)
        var shown = numbers, still = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let now = numbers
            if now != shown { shown = now; still = Date() }
            if !shown.isEmpty, Date().timeIntervalSince(still) >= quiet { return shown }
        }
        return shown
    }

    private func turnForward() {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    func testEveryTurnMovesOnAPageAndAReopenKeepsTheNumbers() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
                                        "-GatefoldGoTo", ProcessInfo.processInfo.environment["GATEFOLD_NUMBERS_AT"] ?? "0.31"]
        app.launch()
        var shown = settledNumbers(timeout: 300)
        XCTAssertFalse(shown.isEmpty, "no page number once the book was counted")
        let page = app.descendants(matching: .any)["reader.page"].firstMatch.frame
        let perScreen = page.width > page.height ? 2 : 1
        var sequence = [shown]
        for _ in 0..<10 {
            let before = visibleText
            turnForward()
            let moved = Date().addingTimeInterval(15)
            while visibleText == before, Date() < moved { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            let next = settledNumbers(timeout: 15, quiet: 0.8)
            sequence.append(next)
            if let a = shown.last, let b = next.last {
                XCTAssertEqual(b - a, perScreen, "a turn from \(shown) to \(next)")
            }
            if next.count == 2 { XCTAssertEqual(next[1], next[0] + 1, "a spread's numbers \(next)") }
            shown = next
        }
        let note = XCTAttachment(string: sequence.map { $0.map(String.init).joined(separator: "/") }.joined(separator: ", "))
        note.name = "page numbers over ten turns"
        note.lifetime = .keepAlways
        add(note)

        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        sleep(4)
        app.terminate()
        app.launchArguments = common
        app.launch()
        // Kept counts number the reopened page without counting again.
        XCTAssertEqual(settledNumbers(timeout: 40, quiet: 2.5), shown, "the reopen's numbers")
    }
}
