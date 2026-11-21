import XCTest

/// Showing the reader's controls never moves or hides a word (Ari, build 53, 2026-11-20). On the folded Duo, tapping
/// for the controls stepped the page back (a 0.96 scale), laid paper over its top line, and laid paper from the
/// middle of the screen down wherever the trailing column of controls stood on a line: half the words went. Apple
/// Books, Photos and Safari lay their controls over a page that holds still; so does Ouro HX's
/// `.ouroImmersiveControls`.
///
/// With the controls down and then up on the same page, this reads `reader.lineFrames` (where each line of text
/// stands, in window points, measured through the web view's own conversion, so a scale shows) and the screen. Every
/// line keeps its frame, keeps its ink and its brightness (nothing is drawn or dimmed over it), and no control stands on it. The probe never reads
/// the words themselves. Judged in reads, never seconds; `HangGuard` only catches a hang.
@MainActor
final class ControlsOverPageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws { app.terminate() }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var page: XCUIElement { el("reader.page") }

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
        let settled = readsUntil(reads: 100) {
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

    /// Every control on screen: the reader's buttons and its scrubber.
    private func controlFrames() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for id in ["reader.close", "reader.bookmark", "reader.contents", "reader.share", "reader.appearance", "reader.search",
                   "reader.scrubber", "reader.back"] {
            let e = el(id)
            if e.exists, !e.frame.isEmpty { out[id] = e.frame }
        }
        return out
    }

    /// Dark pixels (the ink of a line of text on a light theme) inside `rect`, in window points.
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

    /// The mean brightness (0 to 765, the sum of red, green and blue) inside `rect`, in window points: a dim over the
    /// page lowers it without hiding any ink.
    private func brightness(in rect: CGRect, of shot: XCUIScreenshot, window: CGRect) -> Double {
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let scale = CGFloat(image.width) / window.width
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        let x0 = max(0, Int(((rect.minX - window.minX) * scale).rounded())), x1 = min(image.width, Int(((rect.maxX - window.minX) * scale).rounded()))
        let y0 = max(0, Int(((rect.minY - window.minY) * scale).rounded())), y1 = min(image.height, Int(((rect.maxY - window.minY) * scale).rounded()))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = bytes + y * perRow + x * perPixel
                sum += Int(p[0]) + Int(p[1]) + Int(p[2])
            }
        }
        return Double(sum) / Double((x1 - x0) * (y1 - y0))
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func check(_ extra: [String], name: String) {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldLineFramesProbe", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31", "-GatefoldTheme", "daylight",
        ] + extra
        app.launch()
        let ready = readsUntil(reads: 600) { el("reader.pageReady").exists && (el("reader.pageReady").value as? String) == "1" }
        XCTAssertTrue(ready.ok, "the book opened (\(ready.reads) reads)")
        let window = app.windows.firstMatch.frame
        let contents = app.buttons["reader.contents"]

        let before = settledLines("controls down")
        XCTAssertGreaterThan(before.count, 5, "the probe found the page's lines")
        let down = app.windows.firstMatch.screenshot()
        attach(down, "\(name)-controls-down")

        for _ in 0..<3 where !contents.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { contents.exists && contents.isHittable }
        }
        XCTAssertTrue(contents.exists, "the controls came up")
        let after = settledLines("controls up")
        // The controls' arrival has finished by the time the probe's last pass has read the same three times.
        let up = app.windows.firstMatch.screenshot()
        attach(up, "\(name)-controls-up")
        let controls = controlFrames()

        var moved: [String] = [], inkLost: [String] = [], dimmed: [String] = [], underControl: [String] = []
        let afterSet = Set(after.map { "\($0)" })
        for (i, line) in before.enumerated() {
            if !afterSet.contains("\(line)") { moved.append("line \(i) at \(line)") }
            let was = ink(in: line, of: down, window: window), now = ink(in: line, of: up, window: window)
            if was > 0, Double(now) < 0.85 * Double(was) { inkLost.append("line \(i) at \(line): ink \(was) to \(now)") }
            let lit = brightness(in: line, of: down, window: window), litNow = brightness(in: line, of: up, window: window)
            if litNow < 0.97 * lit { dimmed.append("line \(i) at \(line): brightness \(Int(lit)) to \(Int(litNow))") }
            for (id, frame) in controls where frame.intersects(line) { underControl.append("line \(i) at \(line) under \(id) \(frame)") }
        }
        let last = before.max { $0.maxY < $1.maxY }
        print("CONTROLS OVER PAGE \(name): \(before.count) lines, \(moved.count) moved, \(inkLost.count) lost ink, \(dimmed.count) dimmed, "
              + "\(underControl.count) under a control; last line \(last.map { "\($0)" } ?? "none"); window \(window); "
              + "controls \(controls.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        XCTAssertTrue(moved.isEmpty, "\(name): showing the controls moved \(moved.count) of \(before.count) lines: \(moved.prefix(4).joined(separator: "; "))")
        XCTAssertTrue(inkLost.isEmpty, "\(name): showing the controls hid \(inkLost.count) of \(before.count) lines: \(inkLost.prefix(4).joined(separator: "; "))")
        XCTAssertTrue(dimmed.isEmpty, "\(name): showing the controls dimmed \(dimmed.count) of \(before.count) lines: \(dimmed.prefix(4).joined(separator: "; "))")
        XCTAssertTrue(underControl.isEmpty, "\(name): \(underControl.count) lines stand under a control: \(underControl.prefix(4).joined(separator: "; "))")
        if let last {
            XCTAssertGreaterThan(ink(in: last, of: up, window: window), 0, "\(name): the last line \(last) still shows with the controls up")
        }

        // And down again: the page is where it began.
        for _ in 0..<3 where contents.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { !contents.exists }
        }
        XCTAssertFalse(contents.exists, "the controls went down")
        let again = settledLines("controls down again")
        XCTAssertEqual(Set(again.map { "\($0)" }), Set(before.map { "\($0)" }), "\(name): the lines stand where they began once the controls go down")
    }

    /// Pages turned: the page holds still under the controls.
    func testShowingTheControlsLeavesEveryLineTurningPages() { check(["-GatefoldPageTurn", "slide"], name: "pages") }
}
