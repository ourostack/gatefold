/// The page as it is once it shows text: a read made while the web view is still laying the chapter out can find no
/// words on screen, and then only its range can judge it (gatefold#58).
@MainActor
public enum LaidOutPage {
    /// How many reads one look at the page may make before it is taken as it is. Counted in reads, not seconds.
    public static let reads = 24

    /// Reads `read` until the page shows text in a range a page can have (`shows`), at most `reads` reads with a `beat` between them; stops early
    /// once `current` turns false. Returns the last read and how many reads it took.
    ///
    /// A read with no text can't say whose words are on screen: `VisibleRange.contains` then falls back to the
    /// progression. Real unfold at c01be7c (job 131123753460) read the spread right after its words were placed on
    /// the left page and got 1.0..1.0, a range no laid-out page has (Readium's lagging start, the end clamped up to
    /// it), with his place at 0.8765: a lost verdict. Readium's next report, with no move between, was 0.8696.
    public static func read(_ read: () async -> VisibleRange?, beat: () async -> Void,
                            current: () -> Bool = { true }, reads: Int = LaidOutPage.reads) async -> (range: VisibleRange?, reads: Int) {
        await LaidOutPage.read(read, beat: beat, current: current, reads: reads, until: shows)
    }

    /// One page's look, as `read`, from the web view's own columns (`liveVisibleRange`).
    public static func readOnePage(_ read: () async -> VisibleRange?, beat: () async -> Void,
                                   current: () -> Bool = { true }, reads: Int = LaidOutPage.reads) async -> (range: VisibleRange?, reads: Int) {
        await LaidOutPage.read(read, beat: beat, current: current, reads: reads, until: shows)
    }

    private static func read(_ read: () async -> VisibleRange?, beat: () async -> Void, current: () -> Bool, reads: Int,
                             until laidOut: (VisibleRange) -> Bool) async -> (range: VisibleRange?, reads: Int) {
        var range = await read()
        var made = 1
        while range.map({ !laidOut($0) }) ?? true, made < reads, current(), !Task.isCancelled {
            await beat()
            guard current() else { break }
            range = await read()
            made += 1
        }
        return (range, made)
    }

    /// A read of a laid-out page: it has words, and a range a page can have. One that starts past its chapter's end
    /// or ends where it starts was made while the web view laid the page out again (Real unfold at c60ef7e, job
    /// 132884768222: 2.4..2.4, with words that weren't the page's), so its words can't judge the page either.
    /// For a spread's live read only (`keepOnLeft`): a single page read with Readium's lagging start can end where it
    /// starts and still be a page.
    static func shows(_ range: VisibleRange) -> Bool {
        range.text != nil && range.start <= 1 && range.end > range.start
    }
}
