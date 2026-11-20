import UIKit
import XCTest

/// Fine-Tune's Justify is his choice of look, never a move. Build 47's random-gesture run on the iPad flipped it and
/// the page came back starting 661 characters before his words, his place halfway down a page he had already read
/// (`UNEXPECTED-MOVE`, finetune-justify-switch-close): Justify also set the line height, so the book was cut into new
/// pages. On the folded Duo every new look also reworked the margins the book had opened with. Flipped on and then
/// off, at four places in the book, the page must still start with the words he was reading. Pages are compared by a
/// hash of their words, never the words (no book text in a log). Judged in reads.
@MainActor
final class JustifyPlaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func say(_ s: String) { print("JUSTIFYPLACE \(s)") }

    private func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }
    /// A page's words as a hash, for logs and messages: FNV-1a over its first 12 words.
    private func hash(_ text: String) -> String {
        var h: UInt32 = 0x811C_9DC5
        for b in words(text).prefix(12).joined(separator: " ").utf8 { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return String(format: "%08x", h)
    }

    /// Reads of the app until `done`, each at least 0.2 s apart; the hang guard only catches a hang.
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > guardEnds { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (false, reads, false)
    }

    /// Opens the book fresh at `at` of the way through and returns its settled page.
    private func open(at: String) -> String {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", at]
        app.launch()
        let page = ReaderReads.settle(app, "the page opened at \(at)") { say($0) }.words
        say("opened at \(at) on \(hash(page))")
        return page
    }

    /// Taps the page's middle until the controls show `button`: a tap, then up to 10 reads for them, 4 times.
    private func showChrome(_ button: String) {
        var shown = (ok: false, reads: 0, hung: false)
        for _ in 0..<4 where !app.buttons[button].exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            shown = readsUntil(reads: 10) { app.buttons[button].exists }
            if shown.hung { break }
        }
        XCTAssertTrue(app.buttons[button].exists, "the controls came up with \(button)\(shown.hung ? " (hang guard)" : "")")
    }

    /// Your Page, then Fine-Tune, scrolled to Justify. Returns the switch.
    private func openJustify() -> XCUIElement {
        showChrome("reader.appearance")
        app.buttons["reader.appearance"].tap()
        let fineTune = app.buttons["appearance.customize"]
        let offered = readsUntil(reads: 40) { fineTune.exists }
        XCTAssertTrue(offered.ok, "Your Page's Fine-Tune within \(offered.reads) reads\(offered.hung ? " (hang guard)" : "")")
        if !HitCheck.hittable(fineTune, in: app) { el("appearance.panel").swipeUp() }
        fineTune.tap()
        let justify = app.switches["appearance.justify"].firstMatch
        let listed = readsUntil(reads: 40) { justify.exists }
        XCTAssertTrue(listed.ok, "Justify within \(listed.reads) reads\(listed.hung ? " (hang guard)" : "")")
        // Asked through HitCheck: the panel is still sliding in, and `isHittable` on a moving switch fails the test.
        for _ in 0..<4 where !HitCheck.hittable(justify, in: app) { el("appearance.panel").swipeUp() }
        return justify
    }

    /// Flips Justify and waits for whatever it reflowed to settle; returns the page then.
    private func flip(_ justify: XCUIElement, _ what: String) -> String {
        let was = (justify.value as? String) ?? "?"
        let reflowBefore = ReaderReads.reflowNumber(app)
        justify.press(forDuration: 0)
        let flipped = readsUntil(reads: 40) { ((justify.value as? String) ?? "?") != was }
        XCTAssertTrue(flipped.ok, "\(what): Justify changed within \(flipped.reads) reads\(flipped.hung ? " (hang guard)" : "")")
        // A flip that lays the page out again settles its reflow first; one that doesn't leaves no reflow to wait on.
        let reflowed = readsUntil(reads: 15) { ReaderReads.reflowNumber(app) > reflowBefore }.ok
        if reflowed {
            XCTAssertNotNil(ReaderReads.reflowSettled(app, since: reflowBefore, what) { say($0) }, "\(what): its reflow settled")
        }
        let page = ReaderReads.settle(app, "the page after \(what)") { say($0) }.words
        say("\(what): reflowed \(reflowed), page \(hash(page)), anchorCheck \(el("reader.anchorCheck").label)")
        return page
    }

    /// Where `his` starts in `page`, in words: 0 when the page starts with them, nil when they are off it.
    private func wordsBefore(_ his: [Substring], in page: String) -> Int? {
        let all = words(page)
        guard !his.isEmpty, all.count >= his.count else { return nil }
        return (0...(all.count - his.count)).first { Array(all[$0..<($0 + his.count)]) == his }
    }

    /// Justify on and then off, at `at`: after each flip the page starts with his first whole words.
    private func flipKeepsHisPage(at: String) {
        let before = open(at: at)
        // The first word can be the end of one begun on the page before: his first whole words follow it.
        let his = Array(words(before).dropFirst().prefix(6))
        XCTAssertFalse(his.isEmpty, "\(at): the page had words")
        let justify = openJustify()
        for what in ["Justify on at \(at)", "Justify off at \(at)"] {
            let after = flip(justify, what)
            let at = wordsBefore(his, in: after)
            say("\(what): \(hash(before)) -> \(hash(after)); his first words \(at.map { "\($0) words down" } ?? "off the page")")
            XCTAssertNotNil(at, "\(what): his first whole words left the page (\(hash(before)) to \(hash(after)))")
            // He was reading from the top of his page: at most the part word he started on comes before them.
            if let at { XCTAssertLessThanOrEqual(at, 1, "\(what): the page starts \(at) words before his (\(hash(before)) to \(hash(after)))") }
        }
    }

    /// Justify on, then the app ended from the Home Screen and opened again: the page he comes back to starts with the
    /// words the flip left him on. Build 47's Duo run came back on the page from before its Fine-Tune changes: the
    /// screen had been laid out with other margins than the place was saved against.
    func testJustifyThenReopenKeepsHisPage() {
        let before = open(at: "0.47")
        let his = Array(words(before).dropFirst().prefix(6))
        let justify = openJustify()
        let flipped = flip(justify, "Justify on before a reopen")
        let at = wordsBefore(his, in: flipped)
        XCTAssertNotNil(at, "the flip kept his first whole words on the page (\(hash(before)) to \(hash(flipped)))")
        // What the flip left on screen is his place now: its first whole words are what a reopen must start with.
        let left = Array(words(flipped).dropFirst().prefix(6))
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.quit()
        app.launchArguments = common + ["-GatefoldOpenBook", "gutenberg-pride-and-prejudice"]
        app.relaunch()
        let back = ReaderReads.settle(app, "the page reopened") { say($0) }.words
        let backAt = wordsBefore(left, in: back)
        say("reopen after Justify: \(hash(flipped)) -> \(hash(back)); his first words \(backAt.map { "\($0) words down" } ?? "off the page")")
        XCTAssertNotNil(backAt, "the reopen kept his first whole words on the page (\(hash(flipped)) to \(hash(back)))")
        if let backAt { XCTAssertLessThanOrEqual(backAt, 1, "the reopened page starts \(backAt) words before his (\(hash(flipped)) to \(hash(back)))") }
    }

    // One place a test, each about 2 min, so each fits a shard's 5 min.
    func testJustifyKeepsHisPageAtAnEighth() { flipKeepsHisPage(at: "0.12") }
    func testJustifyKeepsHisPageAtAThird() { flipKeepsHisPage(at: "0.31") }
    func testJustifyKeepsHisPageAtTheMiddle() { flipKeepsHisPage(at: "0.47") }
    func testJustifyKeepsHisPageAtThreeQuarters() { flipKeepsHisPage(at: "0.73") }
}
