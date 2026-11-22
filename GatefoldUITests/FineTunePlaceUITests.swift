import UIKit
import XCTest

/// Fine-Tune's font, text size, line spacing and margins change how the book looks, never where he is: after each
/// change the page still starts with the words he was reading (at most the part word he began on comes before them).
/// Justify has its own check (`JustifyPlaceUITests`). Each setting is changed and changed back, so a drift that adds up
/// over two changes shows too. Pages are compared by a hash of their words, never the words (no book text in a log).
/// Judged in reads.
@MainActor
final class FineTunePlaceUITests: XCTestCase {
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
    private func say(_ s: String) { print("FINETUNEPLACE \(s)") }

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

    /// Your Page open (the size buttons are on it).
    private func openYourPage() {
        showChrome("reader.appearance")
        app.buttons["reader.appearance"].tap()
        let fineTune = app.buttons["appearance.customize"]
        let offered = readsUntil(reads: 40) { fineTune.exists }
        XCTAssertTrue(offered.ok, "Your Page opened within \(offered.reads) reads\(offered.hung ? " (hang guard)" : "")")
    }

    /// Your Page, then Fine-Tune (fonts, spacing and margins).
    private func openFineTune() {
        openYourPage()
        let fineTune = app.buttons["appearance.customize"]
        if !HitCheck.hittable(fineTune, in: app) { el("appearance.panel").swipeUp() }
        fineTune.tap()
        let margins = el("appearance.margins")
        let listed = readsUntil(reads: 40) { margins.exists }
        XCTAssertTrue(listed.ok, "Fine-Tune within \(listed.reads) reads\(listed.hung ? " (hang guard)" : "")")
    }

    /// Taps `control` (found anew each time) and waits for the reflow it starts to settle; returns the page then.
    private func change(_ what: String, _ control: () -> XCUIElement) -> String {
        let reflowBefore = ReaderReads.reflowNumber(app)
        let target = control()
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(what): its control is there")
        for _ in 0..<4 where !HitCheck.hittable(target, in: app) { el("appearance.panel").swipeUp() }
        target.tap()
        let reflowed = readsUntil(reads: 40) { ReaderReads.reflowNumber(app) > reflowBefore }
        XCTAssertTrue(reflowed.ok, "\(what): the page was laid out again within \(reflowed.reads) reads\(reflowed.hung ? " (hang guard)" : "")")
        if reflowed.ok {
            XCTAssertNotNil(ReaderReads.reflowSettled(app, since: reflowBefore, what) { say($0) }, "\(what): its reflow settled")
        }
        let page = ReaderReads.settle(app, "the page after \(what)") { say($0) }.words
        say("\(what): page \(hash(page)), anchorCheck \(el("reader.anchorCheck").label)")
        return page
    }

    /// Where `his` starts in `page`, in words: 0 when the page starts with them, nil when they are off it.
    private func wordsBefore(_ his: [Substring], in page: String) -> Int? {
        let all = words(page)
        guard !his.isEmpty, all.count >= his.count else { return nil }
        return (0...(all.count - his.count)).first { Array(all[$0..<($0 + his.count)]) == his }
    }

    /// At `at`, makes each change in turn; after each, the page starts with the first whole words he opened on.
    private func changesKeepHisPage(at: String, fineTune: Bool,
                                    _ steps: [(String, () -> XCUIElement)]) {
        let before = open(at: at)
        // The first word can be the end of one begun on the page before: his first whole words follow it.
        let his = Array(words(before).dropFirst().prefix(6))
        XCTAssertFalse(his.isEmpty, "\(at): the page had words")
        if fineTune { openFineTune() } else { openYourPage() }
        for (what, control) in steps {
            let after = change("\(what) at \(at)", control)
            let down = wordsBefore(his, in: after)
            say("\(what) at \(at): \(hash(before)) -> \(hash(after)); his first words \(down.map { "\($0) words down" } ?? "off the page")")
            XCTAssertNotNil(down, "\(what) at \(at): his first whole words left the page (\(hash(before)) to \(hash(after)))")
            if let down { XCTAssertLessThanOrEqual(down, 1, "\(what) at \(at): the page starts \(down) words before his (\(hash(before)) to \(hash(after)))") }
        }
    }

    private func segment(_ picker: String, _ label: String) -> () -> XCUIElement {
        { self.el(picker).buttons[label].firstMatch }
    }

    func testAFontChangeKeepsHisPage() {
        changesKeepHisPage(at: "0.47", fineTune: true, [
            ("Georgia", { self.el("font.georgia") }),
            ("System font", { self.el("font.system") }),
        ])
    }

    func testATextSizeChangeKeepsHisPage() {
        changesKeepHisPage(at: "0.47", fineTune: false, [
            ("Larger text", { self.app.buttons["appearance.larger"] }),
            ("Larger text again", { self.app.buttons["appearance.larger"] }),
            ("Smaller text", { self.app.buttons["appearance.smaller"] }),
        ])
    }

    func testALineSpacingChangeKeepsHisPage() {
        changesKeepHisPage(at: "0.31", fineTune: true, [
            ("Airy spacing", segment("appearance.lineSpacing", "Relaxed")),
            ("Snug spacing", segment("appearance.lineSpacing", "Compact")),
        ])
    }

    func testAMarginsChangeKeepsHisPage() {
        changesKeepHisPage(at: "0.73", fineTune: true, [
            ("Roomy margins", segment("appearance.margins", "Wide")),
            ("Slim margins", segment("appearance.margins", "Narrow")),
        ])
    }
}
