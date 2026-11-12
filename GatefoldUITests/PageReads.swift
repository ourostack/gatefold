import XCTest

/// Waits judged in reads of the app and the reader's own reports, never seconds (gatefold#94, #214). The hang guard
/// (`HangGuard`) only catches a hang. Shared by every test that waits on the page's words.
@MainActor
enum PageReads {
    /// Reads `settle` waits while the opening cover is up (`reader.pageReady` 0): 1200, at least 0.3 s apart, as
    /// CountingPlaceholder's page-ready wait (#94). The app keeps that cover up while the chapter loads, so a reopen on a
    /// starved host can show no words for over a minute: 63 s in #238's round 2 (run 43214477644), still loading after
    /// 67 s in #195's round 4 (run 43238536988). The old 60 s settle returned an empty page then, hashed e3b0c44298fc
    /// (#214), though the screen still showed the cover.
    static let settleReads = 1200
    /// Reads the words get once the reader reports its page ready: past that, an empty page is a blank page, an app
    /// defect, and fails at once instead of waiting out the cover's allowance.
    static let readyReads = 200
    /// Reads (at least 0.1 s apart, `until`) a wait on a jump gets: 1200. #307's round 4 (run 43241520045) ran out of
    /// 600, about 90 s, with Catch up's jump still on its way to its chapter (#94, #214).
    static let veilReads = 1200
    /// Reads that must repeat the words unchanged: 9, so 9 gaps of at least 0.3 s, no less than the old 2.5 s.
    static let quietReads = 9

    private static func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    static func words(_ app: XCUIApplication) -> String { (el(app, "reader.visibleText").value as? String) ?? "" }

    /// Reads of the app until `done`, never seconds (gatefold#94): each read waits at least 0.1 s, so `reads` is the
    /// floor a fast runner gets. The hang guard only catches a hang: `HangGuard` sizes it from `reads` and ends it
    /// before the step does.
    static func until(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > guardEnds { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads, false)
    }

    /// The page's words once they have come and then repeated unchanged for `quietReads` reads, and the reads it took.
    /// Judged in reads and the reader's own ready report. Empty words never count as settled. `note` gets a line for
    /// the log when the wait fails, so a caller can tag it for the step's log filter.
    static func settle(_ app: XCUIApplication, _ what: String, note: (String) -> Void = { print($0) }) -> (words: String, reads: Int) {
        let ready = el(app, "reader.pageReady")
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: settleReads))
        var last = "", same = 0, readyAt: Int?
        for read in 1...settleReads {
            let now = words(app)
            if now == last { same += 1 } else { last = now; same = 0 }
            if !now.isEmpty, same >= quietReads { return (now, read) }
            if readyAt == nil, (ready.value as? String) == "1" { readyAt = read }
            if let readyAt, now.isEmpty, read - readyAt >= readyReads {
                note("\(what) blank: the page was ready at read \(readyAt) and showed no words \(readyReads) reads later")
                XCTFail("\(what): the page was ready and showed no words for \(readyReads) reads")
                return (now, read)
            }
            if Date() > guardEnds {
                XCTFail("hang: \(what) ran \(read) reads without settled words")
                return (now, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        note("\(what) no settled words after \(settleReads) reads (words \(!last.isEmpty), ready \(readyAt.map(String.init) ?? "never"))")
        XCTFail(last.isEmpty ? "\(what): the page never showed words in \(settleReads) reads"
                             : "\(what): the words never held still in \(settleReads) reads")
        return (last, settleReads)
    }
}
