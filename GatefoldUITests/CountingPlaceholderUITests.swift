import UIKit
import XCTest

/// With page numbers on, a book opened for the first time takes a while to count (half a minute on
/// the Duo and the iPad on its side). The number's slot is never blank meanwhile: a quiet "Counting
/// pages…" sits where the number will be, and neither it nor the number moves the words.
@MainActor
final class CountingPlaceholderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    /// Waits are judged in reads of the app, never seconds (gatefold#94, as FineTuneTap in #121): each read is a round
    /// trip to the app, so a starved runner makes reads slower instead of failing what landed late. Each read waits
    /// at least 0.1 s, so `reads` sets the floor a fast runner gets (the old seconds); `hangGuard` ends it on a
    /// runner so slow that the reads would run on (300 s for the page, 2.5 times the old 120 s).
    private func readsUntil(reads: Int, hangGuard: TimeInterval, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(hangGuard)
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > hung { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads, false)
    }

    private func freshOpenNeverLeavesTheSlotBlank() {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldPageFurniture", "YES",
            "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
        ]
        app.launch()
        let number = app.descendants(matching: .any)["reader.pageNumber"].firstMatch
        let counting = app.descendants(matching: .any)["reader.pageCounting"].firstMatch
        // From the moment the page is up, the slot holds the placeholder or the number. Only cheap reads
        // while sampling (the page's text takes seconds to read).
        let ready = app.descendants(matching: .any)["reader.pageReady"].firstMatch
        let shows = readsUntil(reads: 1200, hangGuard: 300) { ready.exists && (ready.value as? String) == "1" }
        print("PLACEHOLDER page ready=\(shows.ok) after \(shows.reads) reads\(shows.hung ? " (hang guard)" : "")")
        XCTAssertTrue(shows.ok, shows.hung ? "the page shows (the hang guard ran out after \(shows.reads) reads)"
                                           : "the page shows (not in \(shows.reads) reads)")
        guard shows.ok else { return }
        var sawCounting = false, samples = 0, words = ""
        let deadline = Date().addingTimeInterval(300)
        while !number.exists, Date() < deadline {
            samples += 1
            if counting.exists {
                // One snapshot for the label: the placeholder can go between `exists` and a second
                // query (a starved runner takes seconds per query), and a query for an element that
                // has gone fails the test (main at 379fda7: found at one read, gone at the next).
                if !sawCounting, let snapshot = try? counting.snapshot() {
                    sawCounting = true
                    XCTAssertEqual(snapshot.label, "Counting pages", "VoiceOver hears what the slot says")
                    words = visibleText
                }
            } else if !number.exists {
                XCTFail("sample \(samples): the page is up and the number's slot is blank")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(number.exists, "the number comes")
        let goes = readsUntil(reads: 20, hangGuard: 60) { !counting.exists }
        print("PLACEHOLDER gone=\(goes.ok) after \(goes.reads) reads\(goes.hung ? " (hang guard)" : "")")
        XCTAssertTrue(goes.ok, goes.hung ? "and the placeholder goes (the hang guard ran out after \(goes.reads) reads)"
                                         : "and the placeholder goes (not in \(goes.reads) reads)")
        print("PLACEHOLDER saw counting=\(sawCounting) samples=\(samples) app drew it=\((app.descendants(matching: .any)["reader.countingShown"].firstMatch.value as? String) ?? "?")")
        // A reset leaves nothing counted, so a fresh open always has a moment before its number. On a
        // slow runner one accessibility read can outlast that moment, so the app's own record counts too.
        let shown = app.descendants(matching: .any)["reader.countingShown"].firstMatch
        XCTAssertTrue(sawCounting || (shown.value as? String) == "1", "the placeholder showed while the count ran")
        if sawCounting, !words.isEmpty {
            sleep(1)
            XCTAssertEqual(visibleText, words, "the number taking the placeholder's place doesn't move the words")
        }
    }

    /// Diagnostic only (gatefold#94, not for merge): a probe that never comes, so both read waits must run out and fail.
    func testRedProofReadsRunOutOnAProbeThatNeverComes() {
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldReset", "YES"]
        continueAfterFailure = true  // an expected failure still stops the test otherwise, and the second wait never runs
        app.launch()
        let never = app.descendants(matching: .any)["reader.noSuchProbe"].firstMatch
        for (reads, guardS) in [(20, 60.0), (1200, 300.0)] {
            let t = Date()
            let r = readsUntil(reads: reads, hangGuard: guardS) { never.exists }
            print(String(format: "PLACEHOLDER red proof: ok=%@ after %d of %d reads (%.1f s)%@", "\(r.ok)", r.reads, reads,
                         Date().timeIntervalSince(t), r.hung ? " (hang guard)" : ""))
            XCTExpectFailure("a probe that never comes must fail the wait") { XCTAssertTrue(r.ok) }
        }
    }

    func testAFreshOpenNeverLeavesTheNumbersSlotBlank() {
        freshOpenNeverLeavesTheSlotBlank()
    }

    func testAFreshOpenOnItsSideNeverLeavesTheNumbersSlotBlank() {
        XCUIDevice.shared.orientation = .landscapeLeft
        freshOpenNeverLeavesTheSlotBlank()
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.width, frame.height, "it really was on its side")
    }
}
