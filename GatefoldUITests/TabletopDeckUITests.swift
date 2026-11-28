import XCTest

/// Half open on a table, the page is the canvas and its controls float over it (Ari, 2026-11-27). The Duo's tabletop
/// put the page in the top half and an opaque deck in the bottom half that nothing put away: the chapter, the turns,
/// the slider and the buttons stood over the lower half whatever he did, and the text stopped at the fold, mid-line
/// in scroll mode. Now the page fills the screen, as it does flat, and the deck is one piece of glass that comes and
/// goes with the rest of the controls, at a tap.
///
/// Every reading mode: the page's lines (`reader.lineFrames`) run on below the fold with the controls down, no deck
/// stands over them, a tap brings the deck up over the lower half and another puts it away. Judged in reads, never
/// seconds; `HangGuard` only catches a hang. Forced (`-GatefoldForcePosture tabletop`), so it runs on the folded
/// Duo's cover screen, which splits at its midline as the inner screen splits at its hinge.
@MainActor
final class TabletopDeckUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    func testTheTabletopDeckFloatsAndGoesInScroll() { check(pageTurn: "scroll") }
    func testTheTabletopDeckFloatsAndGoesWithPages() { check(pageTurn: "curl") }
    func testTheTabletopDeckFloatsAndGoesWithSlides() { check(pageTurn: "slide") }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var deck: XCUIElement { app.buttons["deck.next"] }

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

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
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
            "-GatefoldPageTurn", pageTurn, "-GatefoldForcePosture", "tabletop",
        ]
        app.launch()
        let ready = readsUntil(reads: 600) { el("reader.pageReady").exists && (el("reader.pageReady").value as? String) == "1" }
        XCTAssertTrue(ready.ok, "the book opened (\(ready.reads) reads)")
        XCTAssertEqual(el("reader.posture").label, "tabletop", "the reader stands half open")
        let window = app.windows.firstMatch.frame
        let at = "\(pageTurn), window \(Int(window.width))x\(Int(window.height))"

        // Controls down: no deck, and the page's words run on below the fold.
        let lines = settledLines("controls down")
        attach("\(name)-controls-down")
        XCTAssertFalse(deck.exists && deck.isHittable, "with the controls down no deck stands over the page (\(at))")
        let lowest = lines.map(\.maxY).max() ?? 0
        XCTAssertGreaterThan(lowest, window.midY + 80,
                             "the page's lines run on below the fold (\(at)): the lowest ends at y \(lowest), the fold at \(window.midY)")
        print("TABLETOP \(at): \(lines.count) lines, lowest ends at \(lowest), deck shown \(deck.exists)")

        // A tap brings the deck up with the rest of the controls, over the lower half of the page.
        let centre = el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<3 where !(deck.exists && deck.isHittable) {
            centre.tap()
            _ = readsUntil(reads: 20) { deck.exists && deck.isHittable }
        }
        XCTAssertTrue(deck.exists && deck.isHittable, "a tap brings the deck up (\(at))")
        if deck.exists {
            XCTAssertGreaterThan(deck.frame.minY, window.midY, "the deck floats over the lower half (\(at)), at y \(deck.frame.minY)")
            XCTAssertTrue(lines.contains { $0.intersects(deck.frame) || $0.minY > deck.frame.minY },
                          "the page runs on under the deck (\(at)): no line reaches its top at y \(deck.frame.minY)")
            attach("\(name)-controls-up")
        }

        // And another puts it away.
        centre.tap()
        let gone = readsUntil(reads: 30) { !deck.exists || !deck.isHittable }
        XCTAssertTrue(gone.ok, "a second tap puts the deck away (\(at), \(gone.reads) reads)")
    }
}
