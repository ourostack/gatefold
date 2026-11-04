import XCTest

/// What counting a book's pages behind the page costs: how long each bundled book takes to count,
/// and whether turns stay smooth while it runs (the app logs each turn's late frames, `FrameWatch`).
@MainActor
final class PageCountCostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
    ]

    private static let books = ["alice-in-wonderland", "dracula", "emma", "frankenstein", "moby-dick",
                                "pride-and-prejudice", "sherlock-holmes", "the-great-gatsby"]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }
    private var total: String { (app.descendants(matching: .any)["reader.pageCount"].value as? String) ?? "" }

    private func open(_ book: String) {
        app.launchArguments = common + ["-GatefoldOpenBook", "gutenberg-\(book)", "-GatefoldGoTo", "0.31"]
        app.launch()
        let up = Date().addingTimeInterval(90)
        while visibleText.isEmpty, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    }

    private func note(_ text: String, _ name: String) {
        let a = XCTAttachment(string: text)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func burst(_ n: Int) {
        for _ in 0..<n {
            app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        }
    }

    /// Each bundled book from a clean start: seconds from the page showing to the whole book counted.
    func testEachBookCountsItsPages() {
        var lines: [String] = []
        for book in Self.books where ProcessInfo.processInfo.environment["GATEFOLD_COUNT_BOOK"].map({ $0 == book }) ?? true {
            open(book)
            let shown = Date()
            let done = Date().addingTimeInterval(900)
            while total.isEmpty, Date() < done { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            let line = "\(book): \(total.isEmpty ? "not counted in 900 s" : "\(total) pages in \(Int(Date().timeIntervalSince(shown))) s")"
            lines.append(line)
            XCTAssertFalse(total.isEmpty, line)
            app.terminate()
        }
        note(lines.joined(separator: "\n"), "count times")
    }

    /// Ten turns while the book is being counted, then ten once it is, for the log's frame counts.
    func testTurnsWhileCounting() {
        open("moby-dick")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        burst(10)
        let done = Date().addingTimeInterval(900)
        while total.isEmpty, Date() < done { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertFalse(total.isEmpty, "the book was counted")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        burst(10)
    }
}
