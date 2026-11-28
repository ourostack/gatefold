import XCTest

/// The Back pill floats over the page; it never takes the page's foot away (Ari, 2026-11-27). Opened at another
/// device's place, Gatefold offers "Back to the start" in a Liquid Glass pill, and with it the last few lines of the
/// page went: an opaque band of paper was laid under the pill, from the line above it to the foot of the screen, so
/// the pill "never sat on a line". Glass floats over content: the words run on under it and show around it.
///
/// The check is an overlay check, the shape Ouro Feel's own will take: with the pill up and the controls down, read
/// where every line stands (`reader.lineFrames`) and the screen, and every line shows its ink beside the pill, outside
/// the pill's own frame. The probe never reads the words. A Contents jump brings the pill up here (the Cloud's first
/// open does the same, with the same pill). Judged in reads, never seconds; `HangGuard` only catches a hang.
@MainActor
final class BackPillFloatsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    func testTheBackPillFloatsOverEveryLine() { check(pageTurn: "curl") }
    func testTheBackPillFloatsOverEveryLineInScroll() { check(pageTurn: "scroll") }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        if hung { return (false, 0) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds { hung = true; return (false, read) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (false, reads)
    }

    /// The line frames once the probe's last pass has read the same three times running.
    private func settledLines(_ step: String) -> [CGRect] {
        let probe = el("reader.lineFrames")
        var last = "", same = 0
        let settled = readsUntil(reads: 150) {
            let now = (probe.value as? String) ?? ""
            same = now == last && now.hasPrefix("pass 3: ") ? same + 1 : 0
            last = now
            return same >= 3
        }
        XCTAssertTrue(settled.ok, "\(step): the line frames settled within \(settled.reads) reads (\(last.prefix(80)))")
        return last.dropFirst("pass 3: ".count).split(separator: ";").compactMap { item in
            let n = item.split(separator: ",").compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }
    }

    /// Dark pixels (a line's ink on a light theme) inside `rect`, in window points.
    private func ink(in rect: CGRect, of shot: XCUIScreenshot, window: CGRect) -> Int {
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let scale = CGFloat(image.width) / window.width
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        let x0 = max(0, Int(((rect.minX - window.minX) * scale).rounded())), x1 = min(image.width, Int(((rect.maxX - window.minX) * scale).rounded()))
        let y0 = max(0, Int(((rect.minY - window.minY) * scale).rounded())), y1 = min(image.height, Int(((rect.maxY - window.minY) * scale).rounded()))
        guard x1 > x0, y1 > y0 else { return 0 }
        var dark = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = bytes + y * perRow + x * perPixel
                if Int(p[0]) + Int(p[1]) + Int(p[2]) < 3 * 110 { dark += 1 }
            }
        }
        return dark
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func check(pageTurn: String) {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldLineFramesProbe", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31", "-GatefoldTheme", "daylight",
            "-GatefoldPageTurn", pageTurn,
        ]
        app.launch()
        let ready = readsUntil(reads: 600) { el("reader.pageReady").exists && (el("reader.pageReady").value as? String) == "1" }
        XCTAssertTrue(ready.ok, "the book opened (\(ready.reads) reads)")
        let window = app.windows.firstMatch.frame
        let at = "\(pageTurn), window \(Int(window.width))x\(Int(window.height))"

        // A Contents jump: the way back comes with it.
        let contents = el("reader.contents")
        for _ in 0..<3 where !contents.exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { contents.exists && contents.isHittable }
        }
        contents.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XL")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Chapter")).firstMatch.waitForExistence(timeout: 10),
                      "the contents list opens")
        XCTAssertTrue(ContentsRow.tap(row, in: app).ok, "the contents list's Chapter XL")
        XCTAssertTrue(readsUntil(reads: 600) { !el("reader.veil").exists }.ok, "the jump's veil lifts")

        // The controls down: the pill stands alone at the foot.
        let back = el("reader.back")
        _ = readsUntil(reads: 30) { contents.exists && contents.isHittable }
        if contents.exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
        XCTAssertTrue(readsUntil(reads: 50) { !contents.exists }.ok, "the controls went down")
        XCTAssertTrue(readsUntil(reads: 50) { back.exists && !back.frame.isEmpty }.ok, "the way back stands on the page alone")

        let lines = settledLines("with the pill up")
        XCTAssertGreaterThan(lines.count, 5, "the probe found the page's lines (\(at))")
        // Let the paper (if any) finish fading in: its own measures run 120, 600 and 1400 ms after the pill comes.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let shot = app.windows.firstMatch.screenshot()
        attach(shot, "\(name)-pill-up")
        let pill = back.frame
        print("BACKPILL \(at): pill \(pill), \(lines.count) lines, last at y \(lines.map(\.maxY).max() ?? 0)")

        // Every line keeps ink beside the pill: the part of it left of the pill and the part right of it, whichever
        // holds words (a short last line of a paragraph may end before the pill).
        var hidden: [String] = []
        for line in lines where line.width > 40 {
            let parts = line.intersects(pill.insetBy(dx: -4, dy: -4))
                ? [CGRect(x: line.minX, y: line.minY, width: max(0, pill.minX - 4 - line.minX), height: line.height),
                   CGRect(x: pill.maxX + 4, y: line.minY, width: max(0, line.maxX - pill.maxX - 4), height: line.height)]
                : [line]
            let shown = parts.filter { $0.width > 8 }.map { ink(in: $0, of: shot, window: window) }.reduce(0, +)
            if shown == 0 { hidden.append("y \(Int(line.minY))") }
        }
        XCTAssertTrue(hidden.isEmpty, "every line shows its words beside the Back pill (\(at)); hidden: \(hidden.joined(separator: ", "))")
    }
}
