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
}
