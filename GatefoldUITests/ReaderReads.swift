import XCTest

/// Waits on the reader judged in reads of the app and the reader's own reports, never seconds (gatefold#94, #214,
/// #122). Each read is a round trip to the app, so a starved runner makes reads slower instead of failing what landed
/// late; a fast runner gets at least the gap between reads times the reads. `HangGuard` ends a wait only on a hang.
///
/// CI's starved runners stall a cold launch or a cold page for minutes: one launch in four or five waits 30 s or more
/// for WebKit's page process (#94), and on main 91ca6ca (run 43301488929) a fresh launch with every book downloading
/// had not opened its book 120 s later (#122). A wall-time wait reads that as a failure.
@MainActor
enum ReaderReads {
    /// Reads a wait gets while the reader is on its way or its opening cover is up (`reader.pageReady` 0): 1200, at
    /// least 0.3 s apart, as CountingPlaceholder's page-ready wait (#94). A reopen on a starved host has shown no words
    /// for over a minute: 63 s in #238's round 2 (run 43214477644), still loading after 67 s in #195's round 4 (run
    /// 43238536988), #214.
    static let coverReads = 1200
    /// Reads the words get once the reader reports its page ready: past that, an empty page is a blank page, an app
    /// defect, and fails at once instead of waiting out the cover's allowance.
    static let readyReads = 200
    /// Reads that must repeat the words unchanged: 9, so 9 gaps of at least 0.3 s, no less than the old 2.5 s.
    static let quietReads = 9
    /// Reads, at least 0.5 s apart, a book gets to be counted once its page is ready: 600, the old 300 s at its 0.5 s
    /// poll. The count runs only once the page is ready (`ReaderModel.countHeld`), so the cover's reads come first.
    static let countReads = 600

    private static func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private static func ready(_ app: XCUIApplication) -> Bool {
        (el(app, "reader.pageReady").value as? String) == "1"
    }

    /// The reader's page is up (`reader.page`, there once the reader has laid out its first frame), and the reads it
    /// took, or nil after `coverReads`. Nothing reports progress before the reader is up (the book downloads, opens
    /// and parses behind the shelf), so this wait is its reads alone. `say` notes the outcome.
    static func opened(_ app: XCUIApplication, _ what: String, say: (String) -> Void,
                       file: StaticString = #filePath, line: UInt = #line) -> Int? {
        let page = el(app, "reader.page")
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: coverReads))
        for read in 1...coverReads {
            if page.exists {
                say("\(what) opened at read \(read)")
                return read
            }
            if Date() > guardEnds {
                XCTFail("hang: \(what) ran \(read) reads without the reader's page", file: file, line: line)
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        say("\(what) not opened after \(coverReads) reads")
        return nil
    }

    /// The page's words once they have come and then repeated unchanged for `quietReads` reads, and the reads it took.
    /// Judged in reads and the reader's own ready report, never seconds (#94, #214). Empty words never count as
    /// settled. `say` notes why a settle failed.
    static func settle(_ app: XCUIApplication, _ what: String, say: (String) -> Void,
                       file: StaticString = #filePath, line: UInt = #line) -> (words: String, reads: Int) {
        let text = el(app, "reader.visibleText")
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: coverReads))
        var last = "", same = 0, readyAt: Int?
        for read in 1...coverReads {
            let now = (text.value as? String) ?? ""
            if now == last { same += 1 } else { last = now; same = 0 }
            if !now.isEmpty, same >= quietReads { return (now, read) }
            if readyAt == nil, ready(app) { readyAt = read }
            if let readyAt, now.isEmpty, read - readyAt >= readyReads {
                say("\(what) blank: the page was ready at read \(readyAt) and showed no words \(readyReads) reads later")
                XCTFail("\(what): the page was ready and showed no words for \(readyReads) reads", file: file, line: line)
                return (now, read)
            }
            if Date() > guardEnds {
                XCTFail("hang: \(what) ran \(read) reads without settled words", file: file, line: line)
                return (now, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        say("\(what) no settled words after \(coverReads) reads (words \(!last.isEmpty), ready \(readyAt.map(String.init) ?? "never"))")
        XCTFail(last.isEmpty ? "\(what): the page never showed words in \(coverReads) reads"
                             : "\(what): the words never held still in \(coverReads) reads", file: file, line: line)
        return (last, coverReads)
    }

    /// The book's page count (`reader.pageCount`), or nil: judged in reads and the reader's own ready report, never
    /// seconds (#122). Up to `coverReads` while the page isn't ready, as the count waits on it, then `countReads` once
    /// it is: a book never counted once its page is ready returns nil, and `say` says which. The caller asserts.
    static func counted(_ app: XCUIApplication, _ what: String, say: (String) -> Void,
                        file: StaticString = #filePath, line: UInt = #line) -> Int? {
        let count = el(app, "reader.pageCount")
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: coverReads + countReads))
        var readyAt: Int?
        for read in 1...(coverReads + countReads) {
            if let v = count.value as? String, let n = Int(v) {
                say("\(what) counted \(n) at read \(read), ready at read \(readyAt.map(String.init) ?? "never")")
                return n
            }
            if readyAt == nil, ready(app) { readyAt = read }
            if let readyAt, read - readyAt >= countReads {
                say("\(what) not counted: the page was ready at read \(readyAt) and had no count \(countReads) reads later")
                return nil
            }
            if readyAt == nil, read >= coverReads {
                say("\(what) not counted: the page was never ready in \(coverReads) reads")
                return nil
            }
            if Date() > guardEnds {
                XCTFail("hang: \(what) ran \(read) reads without a count", file: file, line: line)
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }
}
