import CryptoKit
import UIKit
import XCTest

/// A turn of the iPad that arrives while the page is still moving (a Contents jump still loading its
/// chapter, a page turn mid-flight) must still end on a whole spread. A cold iPad in build 19 could keep
/// the old portrait page up under a frozen leaf, the right page blank, past 14 s. Both halves of the
/// spread must carry words within 20 s of the turn. No book text is printed.
@MainActor
final class RotationMidTransitionUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }

    private func settle(_ timeout: TimeInterval) -> String {
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

    /// The share of dark pixels in each half of the screen along its long side (a landscape spread's
    /// two pages, whichever way the raw picture is turned).
    static func ink(_ image: UIImage) -> (Double, Double)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = 0, b = 0
        let alongX = w >= h
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where px[y * w + x] < 110 {
                if (alongX ? x < w / 2 : y < h / 2) { a += 1 } else { b += 1 }
            }
        }
        let half = Double(w * h) / 8
        return (Double(a) / half, Double(b) / half)
    }

    private func launch(_ extra: [String] = []) {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"] + extra
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        _ = settle(60)
    }

    private func tapContentsRow() {
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(el("reader.contents").waitForExistence(timeout: 5))
        el("reader.contents").tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the contents list is up")
        let pick = rows.element(boundBy: min(30, max(0, rows.count - 1)))
        for _ in 0..<6 where !pick.isHittable { app.swipeUp() }
        pick.tap()
    }

    private func turn() { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }

    private func expectWholeSpread(_ what: String) {
        // Whatever was moving, a spread with words on both pages within 20 s.
        let up = Date().addingTimeInterval(20)
        var last: (Double, Double)?
        while Date() < up {
            if let i = Self.ink(XCUIScreen.main.screenshot().image) {
                last = i
                if i.0 > 0.01, i.1 > 0.01 { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "after-\(what)"; shot.lifetime = .keepAlways; add(shot)
        let ok = (last?.0 ?? 0) > 0.01 && (last?.1 ?? 0) > 0.01
        print("MIDTURN \(what): ink \(last.map { String(format: "%.3f / %.3f", $0.0, $0.1) } ?? "none") \(ok ? "WHOLE" : "STUCK")")
        XCTAssertTrue(ok, "\(what): the spread wasn't whole within 20 s of the turn")
        XCTAssertFalse(settle(30).isEmpty, "\(what): the page's words are readable")
    }

    func testTurningDuringAContentsJump() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch()
        tapContentsRow()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectWholeSpread("a turn of the iPad during a Contents jump")
    }

    /// The last resort: a restore that never comes back (held on purpose) still uncovers the spread
    /// within 20 s of the turn, never the old page under a frozen leaf.
    func testARestoreThatNeverSettlesStillShowsTheSpread() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch(["-GatefoldStallReflow", "YES"])
        XCUIDevice.shared.orientation = .landscapeLeft
        expectWholeSpread("a turn of the iPad whose restore never settles")
    }

    func testTurningDuringAPageTurn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch()
        tapContentsRow()
        turn()
        turn()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectWholeSpread("a turn of the iPad during page turns after a jump")
    }
}
