import XCTest

/// On a two-page spread, the turned leaf lands exactly on the page and stays there: no slide toward
/// the outer edge with the old page showing in the gap, and no jerk back when the overlay lifts.
/// Build 14 on the iPad spread landed about 55 pt out and snapped back (Ari: "page turn animation
/// ends with the page off to the side and is pretty janky before it jerks into the correct
/// position"). The landing report measured only after the snap; `reader.turnSettle` watches the
/// outer page in every frame from the turn's last leg until at least six samples and 0.5 s after it lands.
@MainActor
final class SpreadTurnSettleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    func testSpreadTurnsLandWithoutSliding() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The spread runs on the iPad") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "curl", "-GatefoldForcePosture", "spread",
            "-GatefoldDumpSettle", "YES",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(readsUntil(reads: Self.settleReads, "the reader opens") { page.exists }.ok, "the reader opens")
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        // A tap before the reader is ready would be lost, and fail later as a turn never watched.
        let ready = readsUntil(reads: Self.settleReads, "the reader is ready") { probe.exists && probe.label.hasPrefix("ready") }
        XCTAssertTrue(ready.ok, "the reader is ready within \(Self.settleReads) reads: \(probe.label)")
        sleep(3)
        let settle = app.descendants(matching: .any)["reader.turnSettle"]
        let turns: [(String, CGFloat)] = [("forward", 0.95), ("forward", 0.95), ("forward", 0.95), ("back", 0.05), ("back", 0.05)]
        for (i, (way, x)) in turns.enumerated() {
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            // Judged in reads, never in seconds (#77). On CI's iPad one read of the label took up to 20 s, so the
            // 30 s waiter it replaces got one or two reads, and failed with the report already on the label
            // ("settle 1 frames 10 worst 0 pt", "settle 2 frames 9 worst 1 pt").
            let watched = readsUntil(reads: Self.settleReads, "turn \(i + 1) (\(way)) is watched") { settle.exists && settle.label.hasPrefix("settle \(i + 1) ") }
            print("SETTLE turn \(i + 1) (\(way)) watched=\(watched.ok) after \(watched.reads) reads")
            XCTAssertTrue(watched.ok, "turn \(i + 1) (\(way)) was watched within \(Self.settleReads) reads: \(settle.label)")
            let words = settle.label.split(separator: " ")
            let frames = Int(words[3]) ?? 0, worst = Int(words[5]) ?? 999
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "spread-\(i + 1)-\(way)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertGreaterThanOrEqual(frames, 5, "enough frames were watched (\(settle.label))")
            XCTAssertLessThanOrEqual(worst, 2, "turn \(i + 1) (\(way)): the outer page never strays from its rest (\(settle.label))")
            sleep(1)
        }
    }

    /// The reads a turn's settle report may take. Each read waits at least 0.1 s, so a fast runner gets at least the
    /// 30 s the old waiter gave; a slow one gets as many reads, however long each takes.
    private static let settleReads = 300

    /// As PlaceUndoUITests: the hang guard (`HangGuard`, sized from `reads`, ended before the step) ends only a hang,
    /// and fails naming the wait (`what`); continueAfterFailure is off, so that failure ends the test.
    private func readsUntil(reads: Int, _ what: String, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds {
                XCTFail("hang: \(what): \(read) of its \(reads) reads ran past the hang guard")
                return (false, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }

    /// The default spread as a new reader first sees it (no size, margin or theme chosen): kept as a
    /// picture to set beside Apple Books' default spread (aris-device/4). It asserts nothing, so it runs
    /// only when asked (GATEFOLD_CAPTURE).
    func testDefaultSpreadPicture() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The spread runs on the iPad") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GATEFOLD_CAPTURE"] != nil, "capture only")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(readsUntil(reads: Self.settleReads, "the reader opens") { page.exists }.ok, "the reader opens")
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        // A tap before the reader is ready would be lost, and fail later as a turn never watched.
        let ready = readsUntil(reads: Self.settleReads, "the reader is ready") { probe.exists && probe.label.hasPrefix("ready") }
        XCTAssertTrue(ready.ok, "the reader is ready within \(Self.settleReads) reads: \(probe.label)")
        sleep(3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "default-spread"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
