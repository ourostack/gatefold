import CryptoKit
import UIKit
import XCTest

/// The taste reviewers' recurring checks, run by CI on every build instead of in a driver written again
/// for each review (Ari, 2026-11-04: "confirm you're doing what can be done with deterministic tooling
/// with deterministic tooling"). Pages are compared by hash; no book text is printed or kept.
///
/// Covered elsewhere and run beside these: consecutive numbers and +1/+2 a turn
/// (`PageNumberUITests`), landing at rest (`SpreadTurnSettleUITests`), the tap rate
/// (`FineTuneTapUITests`).
@MainActor
final class ReviewerChecksUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private let base = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES"]

    // MARK: Helpers

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private func note(_ s: String) { print("REVIEWER \(s)") }

    /// The page's words once they have stopped changing for 2.5 s.
    private func settle(_ timeout: TimeInterval = 60) -> String {
        let up = Date().addingTimeInterval(timeout)
        var last = "", since = Date()
        while Date() < up {
            let now = words
            if now != last { last = now; since = Date() }
            if !now.isEmpty, Date().timeIntervalSince(since) > 2.5 { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return words
    }

    @discardableResult
    private func turnForward() -> Bool {
        let before = words
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let up = Date().addingTimeInterval(15)
        while Date() < up {
            if words != before, !words.isEmpty { _ = settle(15); return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func counted(_ timeout: TimeInterval = 300) -> Int? {
        let probe = el("reader.pageCount")
        let up = Date().addingTimeInterval(timeout)
        while Date() < up {
            if let v = probe.value as? String, let n = Int(v) { return n }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    private var numbers: [Int] {
        app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            // The label is formatted for reading ("1,023"); keep the digits.
            .compactMap { Int($0.label.filter(\.isNumber)) }
    }

    private func leaveAndRelaunch() -> String {
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) { XCUIApplication(bundleIdentifier: "com.apple.springboard").activate() }
        sleep(3)
        app.quit()
        app.launchArguments = base
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 90), "the book reopened")
        _ = settle(90)
        sleep(3)
        return settle(15)
    }

    private func openFineTune() {
        let appearance = app.buttons["reader.appearance"]
        for _ in 0..<4 where !appearance.isHittable {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appearance.waitForExistence(timeout: 3)
        }
        appearance.tap()
        let fine = app.buttons["appearance.customize"]
        XCTAssertTrue(fine.waitForExistence(timeout: 10), "Fine-Tune is offered")
        if !fine.isHittable { el("appearance.panel").swipeUp() }
        fine.tap()
    }

    private func pageNumbersSwitch() -> XCUIElement {
        let t = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(t.waitForExistence(timeout: 10), "the Page Numbers switch")
        for _ in 0..<4 where !t.isHittable { el("appearance.panel").swipeUp() }
        return t
    }

    /// Sets Page Numbers through his Fine-Tune switch; the switch's own state is the answer.
    private func setPageNumbers(_ on: Bool) {
        openFineTune()
        let t = pageNumbersSwitch()
        if ((t.value as? String) == "1") != on {
            t.tap()
            let want = on ? "1" : "0"
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", want), evaluatedWith: t)], timeout: 5),
                           .completed, "the switch turned \(on ? "on" : "off")")
        }
        closePanel()
    }

    private func closePanel() {
        for id in ["appearance.close", "appearance.back", "appearance.close"] where app.buttons[id].exists { app.buttons[id].tap(); sleep(1) }
        if el("appearance.panel").exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
        sleep(2)
    }

    private func backToShelf() {
        let close = app.buttons["reader.close"].firstMatch
        for _ in 0..<4 where !(close.exists && close.isHittable) {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = close.waitForExistence(timeout: 3)
        }
        close.tap()
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 20), "back on the shelf")
        sleep(2)
    }

    private func openFromShelf(_ id: String) {
        let cover = el("book.\(id)")
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 20))
        for _ in 0..<8 where !(cover.exists && cover.isHittable) { el("library.grid").swipeUp(); sleep(1) }
        XCTAssertTrue(cover.exists, "\(id) is on the shelf")
        cover.tap()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 60), "\(id) opened")
        _ = settle()
        sleep(2)
    }

    /// The Cloud's place offered on a first open here: take it (the tab brings back an offer that folded).
    /// The offer is tapped only while it is hittable: it can fold into its tab between a look and the tap (#207).
    /// Any type, never `app.buttons` (#165). Judged in looks, not seconds (#94): 200 at least 0.3 s apart (the old
    /// 60 s on a fast runner); the 2400 s guard only catches a hang: a look is up to five
        // queries of the app, and a starved runner has taken 1-2 s a query, so 200 looks can run to about 2000 s.
    private func takeTheOffer() {
        let offer = el("banner.jump"), tab = el("banner.tab")
        let start = Date(), hung = start.addingTimeInterval(2400)
        var looks = 0, taken = false
        while looks < 200, words.isEmpty {
            if Date() > hung { XCTFail("hang: looking for the Cloud's offer ran \(looks) looks over 2400 s"); return }
            looks += 1
            if offer.exists, offer.isHittable { offer.tap(); taken = true; break }
            if tab.exists, tab.isHittable { tab.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let secs = String(format: "%.1f", Date().timeIntervalSince(start))
        guard taken else {
            if words.isEmpty { note("no Cloud offer on a page with no words after \(looks) looks in \(secs) s") }
            return
        }
        note("offer taken after \(looks) looks in \(secs) s")
        // Its own clock, so a slow look above doesn't spend this loop's guard.
        let shown = Date(), stuck = shown.addingTimeInterval(2400)
        var reads = 0
        while reads < 200, words.isEmpty {
            if Date() > stuck { XCTFail("hang: the offer's page ran \(reads) reads over 2400 s without words"); return }
            reads += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private func numbersShown(_ timeout: TimeInterval = 120) -> Bool {
        el("reader.pageNumber").waitForExistence(timeout: timeout)
    }

    // MARK: Reopen returns the same words

    /// From three places, two turns on, then leave and come back three times with turns between: every
    /// reopen shows exactly the page he left (by hash). On the iPad it runs on a spread.
    func testEveryReopenReturnsTheSameWords() {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        var same = 0, total = 0
        for spot in ["0.31", "0.12", "0.47"] {
            app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                          "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", spot]
            app.relaunch()
            XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened at \(spot)")
            _ = settle(120)
            turnForward(); turnForward()
            for round in 0..<3 {
                if round == 1 { turnForward() }
                if round == 2 { turnForward(); turnForward() }
                let left = settle(60)
                let back = leaveAndRelaunch()
                total += 1
                let ok = !left.isEmpty && back == left
                if ok { same += 1 }
                note("reopen at \(spot) round \(round + 1): left \(Self.hash(left)) back \(Self.hash(back)) \(ok ? "SAME" : "MISS")")
                XCTAssertTrue(ok, "reopen at \(spot), round \(round + 1), returned other words (\(Self.hash(left)) then \(Self.hash(back)))")
            }
            app.quit()
        }
        note("REOPEN SUMMARY same=\(same) of \(total)")
    }

    // MARK: True numbers

    /// The book's last page carries the book's count: an exact count ends where the book does.
    func testTheLastPagesNumberIsTheCount() {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldPageFurniture", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.993"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        guard let count = counted() else { return XCTFail("the book was never counted") }
        _ = settle()
        XCTAssertTrue(numbersShown(), "a number is up")
        var last = numbers, turns = 0
        note("start numbers=\(last) labels=\(app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex.map(\.label))")
        while turns < 40, !el("endLeaf").exists, turnForward() {
            turns += 1
            sleep(1)
            note("turn \(turns): numbers=\(numbers) endLeaf=\(el("endLeaf").exists)")
            if !el("endLeaf").exists, !numbers.isEmpty { last = numbers }
        }
        note("last page numbers=\(last) count=\(count) turns=\(turns) endLeaf=\(el("endLeaf").exists)")
        XCTAssertTrue(el("endLeaf").exists, "turning on reached the end of the book")
        XCTAssertEqual(last.last, count, "the last page's number is the book's count")
        if last.count == 2 { XCTAssertEqual(last[1], last[0] + 1, "the last spread's numbers are consecutive") }
    }

    // MARK: Reader-wide toggles

    /// Page Numbers is his setting, not a book's: off by default, on in one book is on in the next (a
    /// book with its own look included), off in one is off in all, kept across a relaunch, and the
    /// words never move.
    func testPageNumbersAreOnOrOffInEveryBook() {
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-emma", "-GatefoldGoTo", "0.2",
                                      // The second book's Cloud offer mustn't fold between a look and the tap (#207).
                                      "-GatefoldOfferFoldSeconds", "600"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        XCTAssertNotNil(counted(), "the book was counted")
        _ = settle()
        // Emma gets a look of its own: one size larger.
        openFineTuneLarger()
        XCTAssertNotNil(counted(), "counted again at the larger size")
        XCTAssertTrue(numbersOff(), "off by default")
        backToShelf()

        openFromShelf("gutenberg-pride-and-prejudice")
        XCTAssertNotNil(counted(), "the second book was counted")
        // Opened here for the first time, it shows its start (a cover, no words) and offers the Cloud's place.
        takeTheOffer()
        let before = settle()
        XCTAssertGreaterThan(before.count, 0, "the page has words")
        XCTAssertTrue(numbersOff(), "off by default in a second book")
        setPageNumbers(true)
        XCTAssertTrue(numbersShown(), "on where he turned it on")
        let after = settle()
        note("words with numbers on: \(Self.hash(before)) then \(Self.hash(after)) numbers=\(numbers) chars=\(before.count)")
        XCTAssertGreaterThan(after.count, 0, "the page has words with numbers on")
        XCTAssertEqual(Self.hash(after), Self.hash(before), "turning numbers on moved no words")
        backToShelf()

        openFromShelf("gutenberg-emma")
        _ = counted(120)
        XCTAssertTrue(numbersShown(), "on in a book with its own look")
        setPageNumbers(false)
        XCTAssertTrue(el("reader.pageNumber").waitForNonExistence(timeout: 10), "off where he turned it off")
        backToShelf()

        openFromShelf("gutenberg-alice-in-wonderland")
        XCTAssertNotNil(counted(), "the third book was counted")
        XCTAssertTrue(numbersOff(), "off in a book never opened")
        backToShelf()

        openFromShelf("gutenberg-pride-and-prejudice")
        XCTAssertNotNil(counted(), "the first book was counted on return")
        XCTAssertTrue(numbersOff(), "off in the book where he had turned it on")
        let again = settle()
        note("words back in the first book: \(Self.hash(before)) then \(Self.hash(again))")
        XCTAssertGreaterThan(again.count, 0, "the page has words on return")
        XCTAssertEqual(Self.hash(again), Self.hash(before), "and its words are where they were")
        let back = leaveAndRelaunch()
        note("words after a relaunch: \(Self.hash(back))")
        XCTAssertGreaterThan(back.count, 0, "the page has words after a relaunch")
        XCTAssertNotNil(counted(), "counted after a relaunch")
        XCTAssertTrue(numbersOff(), "still off after a relaunch")
        XCTAssertEqual(Self.hash(back), Self.hash(before), "on his page after a relaunch")
        if Self.hash(back) != Self.hash(before) {
            // Where he is now, by number, for the report.
            setPageNumbers(true)
            _ = numbersShown()
            note("after a relaunch numbers=\(numbers) chars=\(back.count)")
        }
    }

    /// Neither a number nor the "Counting pages…" slot: asked only once the book is counted, when a
    /// number would be up if the setting were on.
    private func numbersOff() -> Bool {
        sleep(1)
        return !el("reader.pageNumber").exists && !el("reader.pageCounting").exists
    }

    private func openFineTuneLarger() {
        let appearance = app.buttons["reader.appearance"]
        for _ in 0..<4 where !appearance.isHittable {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appearance.waitForExistence(timeout: 3)
        }
        appearance.tap()
        let larger = app.buttons["appearance.larger"].firstMatch
        XCTAssertTrue(larger.waitForExistence(timeout: 10), "the size control")
        larger.tap()
        sleep(2)
        closePanel()
        _ = settle()
    }

    // MARK: Density

    /// The iPad's default spread fills the page as Apple Books' does. Ari's own Apple Books spread
    /// (delight-build14 `aris-device/4-apple-books-spread.jpg`, measured by the reviewers): 18 lines,
    /// the first at 11.3% of the height, the last ending at 82.3%, line pitch ÷ text width 0.071.
    /// Gatefold measured 19, 12.4%, 84.6% and 0.072 when the reviewers called it right. A page can end
    /// early (a chapter opening, a paragraph kept whole), so the fullest of six pages is the one judged.
    func testTheDefaultSpreadIsAsFullAsAppleBooks() throws {
        guard pad else { throw XCTSkip("Apple Books' spread was recorded on the iPad") }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        _ = settle(120)
        var pages: [Density.Measure] = []
        for spread in 0..<3 {
            if spread > 0 { XCTAssertTrue(turnForward(), "turned to spread \(spread + 1)"); _ = settle() }
            sleep(3)
            let shot = XCUIScreen.main.screenshot()
            let window = app.windows.firstMatch.frame
            for band in [(0.0, 0.5), (0.5, 1.0)] {
                guard let m = Density.measure(shot.image, landscape: window.width > window.height, from: band.0, to: band.1) else { continue }
                note(String(format: "density spread %d lines=%d first=%.1f%% last=%.1f%% pitch/textw=%.3f textw/pagew=%.2f",
                            spread + 1, m.lines, m.first * 100, m.last * 100, m.pitchPerWidth, m.widthPerPage))
                pages.append(m)
            }
        }
        guard let m = pages.max(by: { ($0.lines, $0.last) < ($1.lines, $1.last) }) else { return XCTFail("no lines found") }
        note(String(format: "density fullest lines=%d first=%.1f%% last=%.1f%% pitch/textw=%.3f", m.lines, m.first * 100, m.last * 100, m.pitchPerWidth))
        XCTAssertTrue((16...21).contains(m.lines), "lines on a full page: \(m.lines) (Apple Books 18)")
        XCTAssertEqual(m.first, 0.113, accuracy: 0.025, "where the first line starts (Apple Books 11.3%)")
        XCTAssertEqual(m.last, 0.823, accuracy: 0.035, "where the last line ends (Apple Books 82.3%)")
        XCTAssertEqual(m.pitchPerWidth, 0.071, accuracy: 0.008, "line pitch against text width (Apple Books 0.071)")
        XCTAssertEqual(m.widthPerPage, 0.80, accuracy: 0.05, "text width against page width (Apple Books 0.80)")
    }
}

/// The reviewers' line-density measure (`density.py`): dark rows in a column band, grouped into lines.
enum Density {
    struct Measure { let lines: Int; let first: Double; let last: Double; let pitchPerWidth: Double; let widthPerPage: Double }

    /// `landscape`: the screen's way up. XCUIScreen hands back the panel's pixels, which stay portrait
    /// on an iPad turned landscape-left; those are turned a quarter counter-clockwise to read as seen.
    static func measure(_ image: UIImage, landscape: Bool, from x0f: Double, to x1f: Double) -> Measure? {
        guard let raw = image.cgImage else { return nil }
        let turn = landscape && raw.width < raw.height
        let size = turn ? CGSize(width: raw.height, height: raw.width) : CGSize(width: raw.width, height: raw.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { r in
            let c = r.cgContext
            if turn {
                // CoreGraphics draws bottom-up: flip, then turn so the panel's right edge becomes the top.
                c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
                c.translateBy(x: size.width / 2, y: size.height / 2)
                c.rotate(by: .pi / 2)
                c.draw(raw, in: CGRect(x: -size.height / 2, y: -size.width / 2, width: size.height, height: size.width))
            } else {
                c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
                c.draw(raw, in: CGRect(origin: .zero, size: size))
            }
        }
        guard let cg = upright.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let x0 = Int(Double(w) * x0f), x1 = Int(Double(w) * x1f)
        func dark(_ x: Int, _ y: Int) -> Bool { px[y * w + x] < 110 }
        let rows = (0..<h).map { y in stride(from: x0, to: x1, by: 2).reduce(0) { $0 + (dark($1, y) ? 1 : 0) } }
        let threshold = max(3, Int(Double(x1 - x0) / 2 * 0.01))
        var runs: [(Int, Int)] = []
        var y = 0
        while y < h {
            if rows[y] > threshold {
                let s = y
                while y < h, rows[y] > threshold { y += 1 }
                if y - s >= max(4, h / 400) { runs.append((s, y)) }
            }
            y += 1
        }
        let body = runs.filter { Double($0.0) > Double(h) * 0.06 && Double($0.0) < Double(h) * 0.94 }
        // A quotation mark or a dash on its own row is a sliver, not a line.
        let heights = body.map { $0.1 - $0.0 }.sorted()
        guard !heights.isEmpty else { return nil }
        let typical = heights[heights.count / 2]
        let lines = body.filter { $0.1 - $0.0 >= typical / 2 }
        guard lines.count > 1 else { return nil }
        let inkColumns = (x0..<x1).filter { x in stride(from: Int(Double(h) * 0.15), to: Int(Double(h) * 0.85), by: 3).contains { dark(x, $0) } }
        guard let lo = inkColumns.min(), let hi = inkColumns.max(), hi > lo else { return nil }
        let textWidth = Double(hi - lo)
        let gaps = zip(lines.dropFirst(), lines).map { Double($0.0 - $1.0) }.sorted()
        let pitch = gaps[gaps.count / 2]
        return Measure(lines: lines.count, first: Double(lines.first!.0) / Double(h), last: Double(lines.last!.1) / Double(h),
                       pitchPerWidth: pitch / textWidth, widthPerPage: textWidth / Double(x1 - x0))
    }
}
