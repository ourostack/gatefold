import Testing
@testable import GatefoldCore

/// Real unfold at 4688f6d (job 133832660752), folded shut from a spread on a starved runner (load average 400): the
/// cover's restore jumped back to his words and read the page 160 ms after each jump, three times in 1.4 s, and each
/// read showed other words at 1.0..1.0, so the reflow check said his words were lost. 0.7 s later, with no move
/// between, Readium reported the page at 0.7636 and it showed his words: the jump had landed, late. Here the page
/// takes `lag` reads after the first jump to show them. Counted in reads, never seconds.
@MainActor @Suite struct RestoreLandingTests {
    static let file = "OEBPS/chapter-07.html"
    static let his = ReadingAnchor(href: file, progression: 0.796296, text: "the first words of his sentence")
    static let other = VisibleRange(href: file, start: 1, end: 1, text: "words from the end of the chapter")
    static let his_page = VisibleRange(href: file, start: 0.763636, end: 0.8, text: "the first words of his sentence and on")

    @Test func aJumpThatLandsLateIsWaitedFor() async {
        var sent = 0, made = 0
        let lag = 5
        let (range, jumps, reads) = await RestoreLanding.land(
            go: { sent += 1 },
            read: { made += 1; return sent > 0 && made >= lag ? Self.his_page : Self.other },
            beat: {}, arrived: { $0.contains(Self.his) }, current: { true })
        #expect(range.map { $0.contains(Self.his) } == true, "his words read as lost on a page still landing: \(String(describing: range))")
        #expect(reads == lag, "read \(reads) times")
        #expect(jumps <= 2, "sent \(jumps) times")
    }

    /// A page that lands at once is read once, after one jump.
    @Test func aJumpThatLandsAtOnceIsReadOnce() async {
        var sent = 0
        let (range, jumps, reads) = await RestoreLanding.land(
            go: { sent += 1 }, read: { Self.his_page }, beat: {}, arrived: { $0.contains(Self.his) }, current: { true })
        #expect(range == Self.his_page && jumps == 1 && reads == 1 && sent == 1)
    }

    /// A page that never shows his words is still lost once the jumps and their looks run out: waiting never
    /// changes what counts as lost.
    @Test func aPageThatNeverShowsHisWordsIsStillLost() async {
        var sent = 0
        let (range, jumps, reads) = await RestoreLanding.land(
            go: { sent += 1 }, read: { Self.other }, beat: {}, arrived: { $0.contains(Self.his) }, current: { true })
        #expect(range.map { $0.contains(Self.his) } == false)
        #expect(jumps == RestoreLanding.jumps && sent == RestoreLanding.jumps)
        #expect(reads == RestoreLanding.jumps * RestoreLanding.looks)
    }

    /// The restore's budget spent: no more reads and no more jumps.
    @Test func aSpentBudgetStopsAfterItsRead() async {
        var sent = 0
        let (_, jumps, reads) = await RestoreLanding.land(
            go: { sent += 1 }, read: { Self.other }, beat: {}, arrived: { $0.contains(Self.his) },
            current: { true }, more: { false })
        #expect(jumps == 1 && reads == 1 && sent == 1)
    }

    /// Overtaken (a newer reflow, his move): nothing more is read or sent.
    @Test func anOvertakenRestoreStops() async {
        var sent = 0
        var current = true
        let (range, jumps, reads) = await RestoreLanding.land(
            go: { sent += 1; current = false }, read: { Self.his_page }, beat: {}, arrived: { $0.contains(Self.his) },
            current: { current })
        #expect(range == nil && jumps == 1 && reads == 0 && sent == 1)
    }

    // MARK: After the budget (gatefold#686)

    /// gatefold#686 (#664's App run 46143091876, duo-position): a text-size change on a starved Duo. The restore's
    /// three jumps all landed on the page before his while the page was still laying out, its 4 s budget ran out after
    /// 20 reads, and the cover lifted on that page with his words off screen. Here the page lays out for `layoutReads`
    /// reads: until then every read differs from the last and a jump lands on the page before. Once it stands still, a
    /// jump to where his words are now lands on them. Counted in reads, never seconds.
    @Test func aLandingThatRanOutLandsOnHisWordsOnceThePageStandsStill() async {
        let layoutReads = 10
        var made = 0
        var sentTo: [Double] = []
        let read: () async -> VisibleRange? = {
            made += 1
            if !sentTo.isEmpty { return Self.his_page }
            // Still laying out: the page before his, its start moving as more pages come in.
            if made < layoutReads { return VisibleRange(href: Self.file, start: 0.7 + Double(made) / 1000, end: 0.76, text: "the page before his") }
            return VisibleRange(href: Self.file, start: 0.72, end: 0.76, text: "the page before his")
        }
        let (range, jumps, reads) = await RestoreLanding.landLate(
            read: read, beat: {}, locate: { Self.his.progression }, go: { sentTo.append($0) },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(range.map { $0.contains(Self.his) } == true, "the landing ended off his words: \(String(describing: range))")
        #expect(jumps == 1 && sentTo == [Self.his.progression], "sent to \(sentTo)")
        #expect(reads == made && made == layoutReads + 2, "read \(made) times, said \(reads)")
    }

    /// The page stands still on his words already (the budget ran out a read before it showed them): no jump.
    @Test func aLandingThatRanOutOnHisWordsSendsNothing() async {
        var sent = 0
        let (range, jumps, reads) = await RestoreLanding.landLate(
            read: { Self.his_page }, beat: {}, locate: { Self.his.progression }, go: { _ in sent += 1 },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(range == Self.his_page && jumps == 0 && sent == 0 && reads == 1)
    }

    /// His words nowhere in the page as it is laid out now: nothing to land on, so the landing fails once the page
    /// stands still, with no jump.
    @Test func wordsNotInThePageFailOnceItStandsStill() async {
        var sent = 0
        let (range, jumps, reads) = await RestoreLanding.landLate(
            read: { Self.other }, beat: {}, locate: { nil }, go: { _ in sent += 1 },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(range.map { $0.contains(Self.his) } == false)
        #expect(jumps == 0 && sent == 0 && reads == 2)
    }

    /// His words start on the page shown and run on past its end, so its text lacks their opening: a jump there moves
    /// nothing, and none is sent (the one-page break that follows puts them at its top).
    @Test func wordsThatStartOnThePageShownSendNothing() async {
        var sent = 0
        let straddling = VisibleRange(href: Self.file, start: 0.763636, end: 0.8, text: "the end of the page and the first")
        let (_, jumps, reads) = await RestoreLanding.landLate(
            read: { straddling }, beat: {}, locate: { Self.his.progression }, go: { _ in sent += 1 },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(jumps == 0 && sent == 0 && reads == 2)
    }

    /// Another chapter on screen, whose range happens to cover his place's number: no straddle there, his words are
    /// in his own chapter, so the jump is sent.
    @Test func anotherChapterOnScreenStillGetsItsJump() async {
        var sentTo: [Double] = []
        let elsewhere = VisibleRange(href: "OEBPS/chapter-06.html", start: 0.75, end: 0.85, text: "the chapter before")
        let (range, jumps, _) = await RestoreLanding.landLate(
            read: { sentTo.isEmpty ? elsewhere : Self.his_page }, beat: {}, locate: { Self.his.progression },
            go: { sentTo.append($0) }, arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(range == Self.his_page && jumps == 1 && sentTo == [Self.his.progression])
    }

    /// A page that never shows his words, wherever it is sent, ends lost after its jumps and their reads run out: the
    /// landing fails, it never waits on for ever.
    @Test func aLateLandingThatNeverArrivesEnds() async {
        var sent = 0
        let (range, jumps, reads) = await RestoreLanding.landLate(
            read: { Self.other }, beat: {}, locate: { Self.his.progression }, go: { _ in sent += 1 },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(range.map { $0.contains(Self.his) } == false)
        #expect(jumps == RestoreLanding.jumps && sent == RestoreLanding.jumps)
        #expect(reads == RestoreLanding.jumps * (2 + RestoreLanding.looks), "read \(reads) times")
    }

    /// A page that never stands still still gets its jump after `stillReads` reads, and one with no text to read, or
    /// none read at all, lands on his words the same way.
    @Test func aPageThatNeverStandsStillOrHasNoTextStillGetsItsJump() async {
        var made = 0, sent = 0
        let moving: () async -> VisibleRange? = {
            made += 1
            return sent > 0 ? Self.his_page : VisibleRange(href: Self.file, start: Double(made) / 10_000, end: 0.5, text: "moving")
        }
        let (moved, movedJumps, movedReads) = await RestoreLanding.landLate(
            read: moving, beat: {}, locate: { Self.his.progression }, go: { _ in sent += 1 },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
        #expect(moved == Self.his_page && movedJumps == 1 && movedReads == RestoreLanding.stillReads + 1)
        for blank in [VisibleRange(href: Self.file, start: 0.72, end: 0.76, text: nil), nil] {
            var jumped = false
            let (range, jumps, _) = await RestoreLanding.landLate(
                read: { jumped ? Self.his_page : blank }, beat: {}, locate: { Self.his.progression }, go: { _ in jumped = true },
                arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file)
            #expect(range == Self.his_page && jumps == 1, "a page reading \(String(describing: blank)) never got its jump")
        }
    }

    /// No more than `reads` reads in all, whatever the page does.
    @Test func aLateLandingReadsNoMoreThanItsReads() async {
        let (_, _, reads) = await RestoreLanding.landLate(
            read: { Self.other }, beat: {}, locate: { Self.his.progression }, go: { _ in },
            arrived: { $0.contains(Self.his) }, current: { true }, href: Self.file, reads: 7)
        #expect(reads == 7)
    }

    /// Overtaken (a newer reflow, his move): nothing more is read or sent.
    @Test func anOvertakenLateLandingStops() async {
        var sent = 0, made = 0
        var current = true
        let (_, jumps, reads) = await RestoreLanding.landLate(
            read: { made += 1; if made == 2 { current = false }; return Self.other }, beat: {},
            locate: { Self.his.progression }, go: { _ in sent += 1 }, arrived: { $0.contains(Self.his) },
            current: { current }, href: Self.file)
        #expect(jumps == 0 && sent == 0 && reads == 2)
    }
}
