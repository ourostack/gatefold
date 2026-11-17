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
}
