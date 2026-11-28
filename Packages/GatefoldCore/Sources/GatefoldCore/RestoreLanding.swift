/// A reflow's restoring jump to his words, sent and then looked at until the page shows them.
@MainActor
public enum RestoreLanding {
    /// How many times one restore may send its jump.
    public static let jumps = 3
    /// How many reads of the page one jump gets before it is sent again. Counted in reads, not seconds.
    ///
    /// One read per jump called a late landing lost: Real unfold at 4688f6d (job 133832660752), folded shut on a
    /// starved runner, read the cover 160 ms after each of three jumps, 1.4 s in all, and saw other words each time.
    /// 0.7 s later, with no move between, Readium reported his page. A jump still landing is looked at again, not
    /// sent again on top of itself; the restore's own budget (`more`) still ends the wait.
    public static let looks = 8

    /// Sends `go`, then reads the page (a `beat` before each read) until `arrived` says it shows his words, up to
    /// `looks` reads per jump and `jumps` jumps. Stops at once when `current` turns false (a newer reflow, his move)
    /// and after a read when `more` does (the restore's budget spent). Returns the last read and the counts.
    public static func land(go: () async -> Void, read: () async -> VisibleRange?, beat: () async -> Void,
                            arrived: (VisibleRange) -> Bool, current: () -> Bool,
                            more: () -> Bool = { true }) async -> (range: VisibleRange?, jumps: Int, reads: Int) {
        var range: VisibleRange?
        var jumps = 0, reads = 0
        sending: while jumps < Self.jumps {
            await go()
            jumps += 1
            for _ in 0..<looks {
                await beat()
                guard current() else { break sending }
                range = await read()
                reads += 1
                guard current() else { break sending }
                if let range, arrived(range) { break sending }
                guard more() else { break sending }
            }
        }
        return (range, jumps, reads)
    }

    /// How many reads a landing after the budget (`landLate`) may make in all, counted in reads, never seconds. The
    /// #686 restore read the page 20 times in its 4 s; six times that waits out a layout as slow as that one five times
    /// over, and then the landing fails and says so.
    public static let lateReads = 120
    /// How many reads `landLate` waits for the page to stand still before it jumps anyway: a page with no text to read
    /// (a full-page picture), or one that answers nothing, never reads the same twice and still gets its jump.
    public static let stillReads = 12

    /// After `land` ended with his words off the page, its budget spent while the page was still laying out or its
    /// jumps run out: the restore never lifts onto the page before his (gatefold#686). Reads the page (a `beat`
    /// before each read) until it stands still, the same page read twice running or `stillReads` reads; then sends
    /// `go` to where his words are in the page as it is laid out now (`locate`), and gives that jump `looks` reads to
    /// show them. Again, up to `jumps` jumps and `reads` reads in all. Ends at once on a page that shows his words
    /// (`arrived`); when `current` turns false (a newer reflow, his move); when `locate` finds his words nowhere,
    /// with nothing to land on; and when they start on the page already shown in his chapter (`href`), running on past its end, where a jump
    /// moves nothing and the one-page break that follows puts them at its top. Returns the last read and the counts;
    /// a last read without his words is a landing that failed.
    public static func landLate(read: () async -> VisibleRange?, beat: () async -> Void, locate: () async -> Double?,
                                go: (Double) async -> Void, arrived: (VisibleRange) -> Bool, current: () -> Bool,
                                href: String, reads limit: Int = lateReads) async -> (range: VisibleRange?, jumps: Int, reads: Int) {
        var range: VisibleRange?
        var jumps = 0, reads = 0
        func look() async -> Bool {
            guard reads < limit else { return false }
            await beat()
            guard current() else { return false }
            range = await read()
            reads += 1
            return current()
        }
        func onHisWords() -> Bool { range.map(arrived) ?? false }
        sending: while jumps < Self.jumps {
            // Until the page stands still: a page still laying out moves under a jump (#686's three).
            var last: VisibleRange?
            for waited in 1...stillReads {
                guard await look() else { break sending }
                if onHisWords() { break sending }
                if let shown = range, shown == last { break }
                if waited == stillReads { break }
                last = range
            }
            guard let at = await locate(), current() else { break }
            if let shown = range, shown.href == href, at >= shown.start, at < shown.end { break }
            await go(at)
            jumps += 1
            for _ in 0..<looks {
                guard await look() else { break sending }
                if onHisWords() { break sending }
            }
        }
        return (range, jumps, reads)
    }
}
