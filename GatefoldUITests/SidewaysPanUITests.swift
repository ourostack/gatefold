import XCTest

/// A page never pans on an axis it doesn't scroll (Ari, 2026-11-27). In scroll mode he could drag the page sideways,
/// and the left edge of every line went off the screen: the scrolling page took the screen's side safe area (the
/// folded Duo's status column, a phone on its side) as a sideways content inset, which gave the web view room to pan
/// across, a pan nothing ever put back.
///
/// The check is a viewport-pan check, the shape Ouro Feel's own will take: read where every line stands
/// (`reader.lineFrames`, window points through the web view's own conversion, so a sideways offset shows), drag the
/// page across and let go, read again. No line may move sideways, and every line stays inside the window. The probe
/// never reads the words. Judged in reads, never seconds; `HangGuard` only catches a hang.
@MainActor
final class SidewaysPanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    func testScrollModeNeverPansSideways() { check(pageTurn: "scroll") }

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

    /// Where the ink (a line's dark pixels, on a light theme) begins and ends across the window, in window points,
    /// over the rows `rows` covers.
    private func inkEdges(of shot: XCUIScreenshot, window: CGRect, rows: CGRect) -> (CGFloat, CGFloat) {
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0) }
        let scale = CGFloat(image.width) / window.width
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        let y0 = max(0, Int(((rows.minY - window.minY) * scale).rounded())), y1 = min(image.height, Int(((rows.maxY - window.minY) * scale).rounded()))
        var first = image.width, last = -1
        for y in stride(from: y0, to: y1, by: 2) {
            for x in 0..<image.width {
                let p = bytes + y * perRow + x * perPixel
                if Int(p[0]) + Int(p[1]) + Int(p[2]) < 3 * 110 { first = min(first, x); last = max(last, x) }
            }
        }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func check(pageTurn: String) {
        XCUIDevice.shared.orientation = .portrait
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

        let before = settledLines("before the drag")
        XCTAssertGreaterThan(before.count, 5, "the probe found the page's lines (\(at))")
        let outside = before.filter { $0.minX < window.minX - 0.5 || $0.maxX > window.maxX + 0.5 }
        XCTAssertTrue(outside.isEmpty, "every line lies inside the window across (\(at)); outside: \(outside.prefix(3))")
        let band = before.reduce(CGRect.null) { $0.union($1) }
        let restShot = app.windows.firstMatch.screenshot()
        attach(restShot, "\(name)-before")
        let rest = inkEdges(of: restShot, window: window, rows: band)

        // Across the page and let go, both ways. The line probe reads again only when the place changes, which a
        // sideways pan doesn't do, so the screen itself is read: where the ink begins and ends across the page.
        for (dir, from, to) in [("left", 0.75, 0.2), ("right", 0.25, 0.8)] {
            page.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.52)))
            // Let any deceleration end: the same edges three reads running.
            var last: (CGFloat, CGFloat)? = nil, same = 0, shot = app.windows.firstMatch.screenshot()
            _ = readsUntil(reads: 40) {
                shot = app.windows.firstMatch.screenshot()
                let now = inkEdges(of: shot, window: window, rows: band)
                same = last.map { abs($0.0 - now.0) < 0.5 && abs($0.1 - now.1) < 0.5 } == true ? same + 1 : 0
                last = now
                return same >= 2
            }
            attach(shot, "\(name)-after-drag-\(dir)")
            let edges = last ?? rest
            XCTAssertEqual(edges.0, rest.0, accuracy: 1.5,
                           "a drag to the \(dir) never moves the page sideways (\(at)): the ink began at x \(rest.0), then at \(edges.0)")
            XCTAssertEqual(edges.1, rest.1, accuracy: 1.5,
                           "a drag to the \(dir) never moves the page sideways (\(at)): the ink ended at x \(rest.1), then at \(edges.1)")
        }
    }
}
