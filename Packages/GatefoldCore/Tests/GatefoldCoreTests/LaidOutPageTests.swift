import Testing
@testable import GatefoldCore

/// gatefold#58 at c01be7c (Real unfold, job 131123753460): half open, then flat again. The spread settle put his
/// words on the left page; the read of the page straight after came back 1.0..1.0 with his place at 0.8765, so the
/// reflow check said his words were lost. Readium's next report, with nothing moved, was 0.8696: his page.
/// Here the web view is still laying the spread out for `layingOut` reads: they find no words, and their start is
/// Readium's lagging report. Counted in reads, never seconds.
@MainActor @Suite struct LaidOutPageTests {
    static let file = "OEBPS/chapter-10.html"
    static let his = ReadingAnchor(href: file, progression: 0.876543, text: "the first words of his sentence on the left page")

    private func page(layingOut: Int) -> (read: () async -> VisibleRange?, reads: () -> Int) {
        var made = 0
        let read: () async -> VisibleRange? = {
            made += 1
            if made <= layingOut { return VisibleRange(href: Self.file, start: 1, end: 1, text: nil) }
            return VisibleRange(href: Self.file, start: 0.869565, end: 0.891304,
                                text: "the first words of his sentence on the left page and on across the spread")
        }
        return (read, { made })
    }

    @Test func aSpreadStillLayingOutIsReadAgainUntilItShowsHisWords() async {
        let (read, made) = page(layingOut: 3)
        let (range, reads) = await LaidOutPage.read(read, beat: {})
        #expect(range.map { $0.contains(Self.his) } == true, "his words read as lost on a page still laying out: \(String(describing: range))")
        #expect(reads == 4 && made() == 4, "read \(made()) times, said \(reads)")
    }

    /// A laid-out page is read once: nothing waits on a page that already shows its words.
    @Test func aLaidOutPageIsReadOnce() async {
        let (read, made) = page(layingOut: 0)
        let (range, reads) = await LaidOutPage.read(read, beat: {})
        #expect(range.map { $0.contains(Self.his) } == true)
        #expect(reads == 1 && made() == 1)
    }

    /// A page that never shows text is taken as it is once the reads run out, and judged as before.
    @Test func aPageThatNeverShowsTextIsTakenAsItIsAfterItsReads() async {
        let (read, made) = page(layingOut: .max)
        let (range, reads) = await LaidOutPage.read(read, beat: {})
        #expect(reads == LaidOutPage.reads && made() == LaidOutPage.reads)
        #expect(range?.text == nil && range.map { $0.contains(Self.his) } == false)
    }

    /// Overtaken (a newer reflow, his move): no more reads.
    @Test func anOvertakenLookStopsReading() async {
        let (read, made) = page(layingOut: .max)
        var current = true
        let (_, reads) = await LaidOutPage.read(read, beat: { current = false }, current: { current })
        #expect(reads == 1 && made() == 1)
    }
}
