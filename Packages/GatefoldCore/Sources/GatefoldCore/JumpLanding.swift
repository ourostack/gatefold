/// A jump to a place, sent until the page says it is there.
///
/// A web view still loading takes a jump, opens the jump's file at its first page and drops the place
/// inside it (CI's Duo: a jump to 0.993 opened at 0.938, its file's start, and stayed there while the
/// web view took 27 s to load). Waiting longer never brings it; sending the jump again does.
@MainActor
public enum JumpLanding {
    /// How many reads of the page's place one landing may make. Counted in reads, not seconds.
    public static let reads = 150
    /// While the page is short, the jump is sent again once every this many reads.
    public static let resendEvery = 10

    /// Sends the jump (again while the page refuses it or shows somewhere else) until a read of the page
    /// on screen shows `target`. True once landed; false when the reads run out.
    ///
    /// Judged by the page, not by a slice of the book: landed means the screen is in the target's file and
    /// its range there, from where the page starts to where it ends, holds the target's place
    /// (`VisibleRange.contains`, half-open). A margin in book progression can't tell a file's start from a
    /// place a few pages in (run 42418233954 took 0.3003, its file's start, for a jump to 0.31). A target
    /// on its file's first page is on screen at the file's start, so it still lands at once.
    public static func land(target: ReadingAnchor, go: () async -> Bool, visible: () async -> VisibleRange?, beat: () async -> Void) async -> Bool {
        let place = ReadingAnchor(href: target.href, progression: target.progression, text: nil)
        var taken = await go()
        for read in 1...reads {
            await beat()
            if taken, let range = await visible(), range.contains(place) { return true }
            if !taken || read % resendEvery == 0 { taken = await go() }
        }
        return false
    }
}
