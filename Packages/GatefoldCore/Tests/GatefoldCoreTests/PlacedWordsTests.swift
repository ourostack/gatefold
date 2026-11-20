import Testing
@testable import GatefoldCore

/// gatefold#562: a landing's settle put the Cloud's words at the top of the left page, and the read of his first
/// words made straight after found the left page as it was before that move. Here the page answers with the
/// pre-move page for `stale` reads, then with the placed words. Stand-in words, never a book's.
@MainActor @Suite struct PlacedWordsTests {
    static let placed = "the stand-in words the landing placed at the top of the left page"
    static let before = "stand-in words from the top of the left page before the move"

    private func page(stale: Int) -> (read: () async -> String?, reads: () -> Int) {
        var made = 0
        let read: () async -> String? = {
            made += 1
            // As the page's script reads them: the first 64 characters, whitespace as the book has it.
            return String((made <= stale ? Self.before : "the  stand-in words\nthe landing placed at the top of the left page, and on").prefix(64))
        }
        return (read, { made })
    }

    @Test func aReadOfThePageBeforeTheMoveIsReadAgainUntilItShowsThePlacedWords() async {
        let (read, made) = page(stale: 1)
        var beats = 0
        let result = await PlacedWords.read(read, placed: Self.placed, beat: { beats += 1 })
        #expect(result.begun, "kept the page before the move: \(result.words ?? "nil")")
        #expect(PlacedWords.begin(result.words, with: Self.placed))
        #expect(result.reads == 2 && made() == 2 && beats == 1, "read \(made()) times with \(beats) beats, said \(result.reads)")
    }

    /// A page already showing the placed words is read once: nothing waits on it.
    @Test func aPageShowingThePlacedWordsIsReadOnce() async {
        let (read, made) = page(stale: 0)
        let result = await PlacedWords.read(read, placed: Self.placed, beat: {})
        #expect(result.begun && result.reads == 1 && made() == 1)
    }

    /// A page that never shows them is given up on after its reads, and says so.
    @Test func aPageThatNeverShowsThemIsGivenUpOnAfterItsReads() async {
        let (read, made) = page(stale: .max)
        let result = await PlacedWords.read(read, placed: Self.placed, beat: {})
        #expect(!result.begun && result.reads == PlacedWords.reads && made() == PlacedWords.reads)
    }

    /// He moved, or the book closed: no more reads.
    @Test func aReadStopsOnceTheLandingIsNoLongerCurrent() async {
        let (read, made) = page(stale: .max)
        var current = true
        let result = await PlacedWords.read(read, placed: Self.placed, beat: { current = false }, current: { current })
        #expect(!result.begun && made() == 1)
    }

    @Test func wordsBeginWithThePlacedOnesWhateverTheWhitespace() {
        #expect(PlacedWords.begin("  the stand-in\nwords the landing placed", with: Self.placed))
        #expect(!PlacedWords.begin(Self.before, with: Self.placed))
        #expect(!PlacedWords.begin(nil, with: Self.placed))
        #expect(!PlacedWords.begin("", with: Self.placed))
        // A read cut short at the end of a short paragraph still compares on what it has.
        #expect(PlacedWords.begin("the stand-in", with: Self.placed))
    }
}
