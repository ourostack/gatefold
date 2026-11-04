import XCTest

/// "Land on the very page your InkPad left off": he reads a few pages, leaves, iOS ends Gatefold, and
/// it reopens on the page he left, every time. Seeded, at the default size, chained the way a reader
/// chains them (each reopen is where the next reading starts), and across chapter openings.
@MainActor
final class ReopenLandingUITests: XCTestCase {
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

    /// The page's words once they have stopped changing for `quiet` seconds.
    private func settledText(timeout: TimeInterval = 40, quiet: TimeInterval = 2.5) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = visibleText
        var still = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let now = visibleText
            if now != text { text = now; still = Date() }
            if !text.isEmpty, Date().timeIntervalSince(still) >= quiet { return text }
        }
        return text
    }

    private func turnForward() {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// A small deterministic generator, so a failing run can be replayed exactly.
    private struct Seeded {
        var state: UInt64
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
    }

    private func chain(book: String, at goTo: String, reopens: Int, seed: UInt64, turnRange: ClosedRange<Int> = 1...5, freshOpen: Bool = false, toChapterOpening: Bool = false, pause: () -> TimeInterval) {
        var rng = Seeded(state: seed)
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", book, "-GatefoldGoTo", goTo]
        app.launch()
        XCTAssertFalse(settledText(timeout: 90).isEmpty, "the page never came up")
        var misses: [String] = []
        for round in 1...reopens {
            if freshOpen, round > 1 {
                // He opens the book from the shelf this time, not through the reopen.
                app.terminate()
                app.launchArguments = common + ["-GatefoldOpenBook", book]
                app.launch()
                _ = settledText(timeout: 60, quiet: 1.5)
            }
            let turns = rng.next(turnRange)
            var text = visibleText
            for _ in 0..<turns {
                let before = visibleText
                turnForward()
                // A turn into the next chapter's file can take seconds to load; until it lands the old
                // words stay put and look settled. Wait for the new page before counting it read.
                let moved = Date().addingTimeInterval(15)
                while visibleText == before, Date() < moved { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                text = settledText(timeout: 15, quiet: 0.8)
            }
            if toChapterOpening {
                // On to the next spread whose left page opens a chapter (the review's blank-spread case):
                // the running head names the chapter above the left page's first line, so it changes
                // on the spread where a chapter opens the left page.
                let head = app.descendants(matching: .any)["reader.runningHead"].firstMatch
                let chapter = head.label
                for _ in 0..<60 where head.label == chapter {
                    let before = visibleText
                    turnForward()
                    let moved = Date().addingTimeInterval(15)
                    while visibleText == before, Date() < moved { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                    text = settledText(timeout: 15, quiet: 0.8)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(max(0, pause())))
            let left = freshOpen ? visibleText : settledText(timeout: 15, quiet: 1.5)
            let leftPage = app.descendants(matching: .any)["reader.page"].firstMatch.frame
            _ = text
            // He leaves, and iOS ends Gatefold.
            // (Home, not another app: launching Settings on a loaded simulator sometimes timed out.)
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.terminate()
            app.launchArguments = common
            app.launch()
            let picture = app.descendants(matching: .any)["reader.reopenPicture"].firstMatch
            let gone = Date().addingTimeInterval(40)
            while picture.exists, Date() < gone { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            let back = settledText(timeout: 40, quiet: 3)
            let backPage = app.descendants(matching: .any)["reader.page"].firstMatch.frame
            // The same page frame cuts the book into the same pages; a line less and his words move up a page.
            if abs(backPage.height - leftPage.height) > 0.5 || abs(backPage.minY - leftPage.minY) > 0.5 {
                misses.append("round \(round): the page was laid out at \(leftPage) and reopened at \(backPage)")
            }
            let head = String(left.prefix(40))
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(book)-round-\(round)"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("REOPEN-LANDING \(book) round \(round) turns \(turns) left [\(left.prefix(60))] back [\(back.prefix(60))]")
            if !back.hasPrefix(head) {
                misses.append("round \(round) after \(turns) turns: left [\(left.prefix(50))], reopened [\(back.prefix(50))]")
            }
        }
        XCTAssertTrue(misses.isEmpty, "\(book) reopened off his page \(misses.count) of \(reopens) times:\n" + misses.joined(separator: "\n"))
    }

    /// Alice from the end of chapter VI, across the opening of chapter VII.
    func testReopensOnHisPageAcrossAChapterOpening() {
        chain(book: "gutenberg-alice-in-wonderland", at: ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_AT"] ?? "0.52",
              reopens: Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPENS"] ?? "") ?? 6, seed: 7) { 0 }
    }

    /// Opened from the shelf each time, leaving a second after the last turn, as a quick reader does.
    func testReopensOnHisPageAfterAQuickLeave() {
        chain(book: "gutenberg-pride-and-prejudice", at: ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_AT"] ?? "0.33",
              reopens: Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPENS"] ?? "") ?? 6, seed: 23, freshOpen: true) { 1 }
    }

    /// Opened and left without turning a page (the review's second path), across Alice's chapters.
    func testReopensOnHisPageWithoutTurning() {
        chain(book: "gutenberg-alice-in-wonderland", at: ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_AT"] ?? "0.12",
              reopens: Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPENS"] ?? "") ?? 3, seed: 5, turnRange: 0...0) { 0 }
    }

    /// Pride and Prejudice mid-chapter, leaving at once after the last turn.
    func testReopensOnHisPageMidChapter() {
        chain(book: "gutenberg-pride-and-prejudice", at: ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_AT"] ?? "0.31",
              reopens: Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPENS"] ?? "") ?? 6, seed: 11) { 0 }
    }

    /// The Apple Books review's iPad miss: Pride and Prejudice at 0.31, two turns, left on a spread whose
    /// left page opens a chapter; the reopen settled on an empty spread four pages early. Round 1 is
    /// that case; later rounds turn two more from where the reopen left him. iPad, in landscape.
    func testReopensOnHisSpreadAfterTwoTurns() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread needs the iPad's landscape page")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        chain(book: "gutenberg-pride-and-prejudice", at: ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_AT"] ?? "0.31",
              reopens: Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPENS"] ?? "") ?? 3, seed: 3, turnRange: 2...2) { 0 }
    }

    /// The same, left each time on a spread whose left page opens a chapter.
    func testReopensOnASpreadOpeningAChapter() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread needs the iPad's landscape page")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        chain(book: "gutenberg-pride-and-prejudice", at: ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_AT"] ?? "0.30",
              reopens: Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPENS"] ?? "") ?? 3, seed: 3, turnRange: 1...1, toChapterOpening: true) { 0 }
    }
}
