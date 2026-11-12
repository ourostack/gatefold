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
        // Page numbers are off by default (`PageFurnitureUITests`); these tests judge them shown.
        "-GatefoldPageFurniture", "YES",
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

    /// Reads a reopen's numbers wait while the opening cover is up (`reader.pageReady` 0) and the kept counts come in:
    /// 1200, at least 0.3 s apart, as ReopenAfterControls (#315). A stalled reopen on CI's starved iPad showed its page
    /// 52 s after the place read (run 43280151381), past the old 40 s settle, which then read other numbers (#323).
    private static let reopenReads = 1200
    /// Reads the reopen's numbers must repeat unchanged once the page is ready: 9 gaps of at least 0.3 s, no less than
    /// the old 2.5 s.
    private static let quietReads = 9

    /// The reopen's numbers once the reader reports its page ready and they have held for `quietReads` reads. Judged in
    /// reads and the reader's own ready report, never seconds (#94, #323). The hang guard (`HangGuard`) only catches a hang.
    private func reopenedNumbers() -> [Int] {
        let ready = app.descendants(matching: .any)["reader.pageReady"]
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: Self.reopenReads))
        var shown: [Int] = [], same = 0, readyAt: Int?
        for read in 1...Self.reopenReads {
            let now = numbers
            if now == shown { same += 1 } else { shown = now; same = 0 }
            if readyAt == nil, (ready.value as? String) == "1" { readyAt = read }
            if readyAt != nil, !shown.isEmpty, same >= Self.quietReads {
                print("REOPEN round 1: numbers ready at read \(readyAt ?? -1), numbers settled at read \(read)")
                return shown
            }
            if Date() > guardEnds {
                XCTFail("hang: the reopen's numbers ran \(read) reads without settling")
                return shown
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("REOPEN round 1: numbers not settled after \(Self.reopenReads) reads (ready \(readyAt.map(String.init) ?? "never"))")
        return shown
    }

    private func turnForward() {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    }

    func testEveryTurnMovesOnAPageAndAReopenKeepsTheNumbers() {
        turnsAndReopen()
    }

    /// The iPad on its side: a spread, two numbers in a row, each turn two on. (Run on the iPad only.)
    func testOnASpreadEveryTurnMovesOnTwoPages() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        turnsAndReopen()
    }

    private func turnsAndReopen() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
                                        "-GatefoldGoTo", ProcessInfo.processInfo.environment["GATEFOLD_NUMBERS_AT"] ?? "0.31"]
        app.launch()
        // While the book is counted out of sight, the page shows only its own words. (Build 17's first
        // counter sat behind the live page; its chapter never showed on screen here, but it did in
        // the reopen picture kept then, which `ReopenLandingUITests` caught.)
        let up = Date().addingTimeInterval(90)
        while visibleText.isEmpty, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        let counting = XCUIScreen.main.screenshot()
        var shown = settledNumbers(timeout: 300)
        XCTAssertFalse(shown.isEmpty, "no page number once the book was counted")
        let counted = XCUIScreen.main.screenshot()
        let differs = Self.textDifference(counting.image, counted.image)
        if differs > 0.01 {
            for (shot, name) in [(counting, "while-counting"), (counted, "counted")] {
                let a = XCTAttachment(screenshot: shot)
                a.name = name
                a.lifetime = .keepAlways
                add(a)
            }
        }
        XCTAssertLessThanOrEqual(differs, 0.01, "the page while counting is the page once counted (\(differs) of its text differs)")
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
        app.quit()
        app.launchArguments = common
        app.relaunch()
        // Kept counts number the reopened page without counting again.
        XCTAssertEqual(reopenedNumbers(), shown, "the reopen's numbers")
    }

    /// The share of the text area's pixels (the middle 80% of the screen's height, clear of the
    /// running head and the page number) whose darkness differs between two screenshots.
    private static func textDifference(_ a: UIImage, _ b: UIImage) -> Double {
        func gray(_ image: UIImage) -> (data: [UInt8], w: Int, h: Int)? {
            guard let cg = image.cgImage else { return nil }
            let w = cg.width / 4, h = cg.height / 4
            var data = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (data, w, h)
        }
        guard let x = gray(a), let y = gray(b), x.w == y.w, x.h == y.h else { return 1 }
        var differ = 0, total = 0
        for row in (x.h / 10)..<(x.h * 9 / 10) {
            for col in 0..<x.w {
                let i = row * x.w + col
                total += 1
                if abs(Int(x.data[i]) - Int(y.data[i])) > 60 { differ += 1 }
            }
        }
        return total > 0 ? Double(differ) / Double(total) : 1
    }
}
