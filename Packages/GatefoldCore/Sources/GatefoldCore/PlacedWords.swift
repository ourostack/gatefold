/// A landing's words that its settle put at the top of the left page with a column break (`SpreadSettler`, a
/// `.restore`): from then on the left page's first words begin with them, so a read of the first words that doesn't
/// was made of the page as it was before that move.
///
/// gatefold#562 (main run 44739070531, a starved iPad): the settle reported the Cloud's words placed on the left
/// page after its 2 moves, and 113 ms later the read of his first words found the left page as it was before the
/// break. Those words were kept as his place, and the reopen came back one spread early, though the screen had
/// shown the right spread all along. Counted in reads, never seconds.
@MainActor
public enum PlacedWords {
    /// How many reads one look may make before it gives up on the page showing the placed words.
    public static let reads = 8

    /// How much of the words is compared: enough to tell two pages apart, short enough that a read cut at a
    /// paragraph's end still compares.
    static let probeLength = 24

    /// Whether `firstWords` (the left page's first words, as read) begin with `placed`, whatever the whitespace.
    public static func begin(_ firstWords: String?, with placed: String) -> Bool {
        let f = normalized(firstWords ?? ""), p = normalized(placed)
        let n = min(probeLength, f.count, p.count)
        return n > 0 && f.prefix(n) == p.prefix(n)
    }

    /// Reads the left page's first words until they begin with `placed`, at most `reads` reads with a `beat`
    /// between them; stops early once `current` turns false. Returns the last words read, how many reads it took and
    /// whether they begin with `placed`.
    public static func read(_ read: () async -> String?, placed: String, beat: () async -> Void,
                            current: () -> Bool = { true },
                            reads: Int = PlacedWords.reads) async -> (words: String?, reads: Int, begun: Bool) {
        var words = await read()
        var made = 1
        while !begin(words, with: placed), made < reads, current() {
            await beat()
            guard current() else { break }
            words = await read()
            made += 1
        }
        return (words, made, begin(words, with: placed))
    }

    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
