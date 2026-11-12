/// The page as it is once it shows text: a read made while the web view is still laying the chapter out finds no
/// words on screen, and its start is whatever Readium last reported, often the layout before (gatefold#58).
@MainActor
public enum LaidOutPage {
    /// How many reads one look at the page may make before it is taken as it is. Counted in reads, not seconds.
    public static let reads = 24

    /// Reads `read` until the page shows text, at most `reads` reads with a `beat` between them; stops early
    /// once `current` turns false. Returns the last read and how many reads it took.
    ///
    /// A read with no text can't say whose words are on screen: `VisibleRange.contains` then falls back to the
    /// progression, and Readium's start lags a layout. Real unfold at c01be7c (job 131123753460) read the
    /// spread right after its words were placed on the left page and got 1.0..1.0, a range no laid-out page has,
    /// with his place at 0.8765: a lost verdict. Readium's next report, with no move between, was 0.8696, his page.
    public static func read(_ read: () async -> VisibleRange?, beat: () async -> Void,
                            current: () -> Bool = { true }, reads: Int = LaidOutPage.reads) async -> (range: VisibleRange?, reads: Int) {
        var range = await read()
        var made = 1
        while range?.text == nil, made < reads, current() {
            await beat()
            guard current() else { break }
            range = await read()
            made += 1
        }
        return (range, made)
    }
}
