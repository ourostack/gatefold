import Testing
@testable import GatefoldCore

/// gatefold#58 at c01be7c (Real unfold, job 131123753460): half open, then flat again. The spread settle put his
/// words on the left page; the read of the page straight after came back 1.0..1.0 with his place at 0.8765, so the
/// reflow check said his words were lost. Readium's next report, with nothing moved, was 0.8696: his page.
/// Here the web view is still laying the spread out for `layingOut` reads: they find no words, and their range is
/// the collapsed one that read had. Counted in reads, never seconds.
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

    /// A page that shows other words is judged lost at once: waiting is only for a page with no words yet.
    @Test func aPageShowingOtherWordsIsStillLost() async {
        var made = 0
        let read: () async -> VisibleRange? = {
            made += 1
            return VisibleRange(href: Self.file, start: 0.869565, end: 0.891304, text: "a page of other words entirely")
        }
        let (range, reads) = await LaidOutPage.read(read, beat: {})
        #expect(reads == 1 && made == 1)
        #expect(range.map { $0.contains(Self.his) } == false, "a page without his words read as his")
    }

    /// Real unfold at c60ef7e (job 132884768222): the spread settle put his words on the left page, and the read
    /// straight after came back 2.4..2.4 with words in it. No laid-out page starts past its chapter's end, or ends where
    /// it starts: the web view was laying the spread out again under that read, and its words were not the page's. The
    /// check said his words were lost; Readium's next report, with nothing moved, was his page. Such a read is read again.
    @Test func aReadWhoseRangeNoPageHasIsReadAgain() async {
        var made = 0
        let read: () async -> VisibleRange? = {
            made += 1
            if made == 1 { return VisibleRange(href: Self.file, start: 2.4, end: 2.4, text: "words from a page still being laid out") }
            if made == 2 { return VisibleRange(href: Self.file, start: 0.9, end: 0.9, text: "words from a page still being laid out") }
            return VisibleRange(href: Self.file, start: 0.869565, end: 0.891304,
                                text: "the first words of his sentence on the left page and on across the spread")
        }
        let (range, reads) = await LaidOutPage.read(read, beat: {})
        #expect(range.map { $0.contains(Self.his) } == true, "his words read as lost on a page still laying out: \(String(describing: range))")
        #expect(reads == 3 && made == 3, "read \(made) times, said \(reads)")
    }

    /// The chapter's last page may end at 1: that range is a page, read once.
    @Test func theChaptersLastPageIsReadOnce() async {
        var made = 0
        let read: () async -> VisibleRange? = {
            made += 1
            return VisibleRange(href: Self.file, start: 0.97, end: 1, text: "the last words of the chapter")
        }
        let (_, reads) = await LaidOutPage.read(read, beat: {})
        #expect(reads == 1 && made == 1)
    }

    /// gatefold#678 (App run 46077756249, attempt 1): turned on its side and back upright, with the new column reaching
    /// Readium after the restore. The look at the page read his words 1110 characters into 2055: the 1106 of the page
    /// before his and the 949 of his own, read while the web view's scroll stood between the two (the screen recording's
    /// last frames show it moving). His words were "on screen", so nothing moved; then the scroll came to rest on the page
    /// before his, with Readium's report at 25 of 31 and his place at 26 of 31, and the page opened on other words.
    /// A one-page read whose scroll stands between two pages is not a page: it is read again.
    @Test func aOnePageReadBetweenTwoPagesIsReadAgain() async {
        let pages = 31.0
        let before = "the page before his, all of it"
        var made = 0
        let read: () async -> VisibleRange? = {
            made += 1
            if made <= 2 {
                return VisibleRange(href: Self.file, start: 25.5 / pages, end: 26.5 / pages,
                                    text: "\(before) the first words of his sentence on the left page and the rest of his page")
            }
            return VisibleRange(href: Self.file, start: 25 / pages, end: 26 / pages, text: before)
        }
        let (range, reads) = await LaidOutPage.readOnePage(read, beat: {})
        #expect(range.map { $0.contains(Self.his) } == false, "a read between two pages called the page before his his: \(String(describing: range))")
        #expect(reads == 3 && made == 3, "read \(made) times, said \(reads)")
    }

    /// A one-page read standing on its page, the last page of a chapter (ending at 1) included, is read once.
    @Test func aOnePageReadOnItsPageIsReadOnce() async {
        let pages = 31.0
        for (start, end) in [(26 / pages, 27 / pages), (0, 1 / pages), (30 / pages, 1)] {
            var made = 0
            let read: () async -> VisibleRange? = {
                made += 1
                return VisibleRange(href: Self.file, start: start, end: end, text: "the first words of his sentence on the left page")
            }
            let (range, reads) = await LaidOutPage.readOnePage(read, beat: {})
            #expect(range.map { $0.contains(Self.his) } == true)
            #expect(reads == 1 && made == 1, "page \(start)..\(end) read \(made) times")
        }
    }

    /// Overtaken (a newer reflow, his move): no more reads.
    @Test func anOvertakenLookStopsReading() async {
        let (read, made) = page(layingOut: .max)
        var current = true
        let (_, reads) = await LaidOutPage.read(read, beat: { current = false }, current: { current })
        #expect(reads == 1 && made() == 1)
    }
}
