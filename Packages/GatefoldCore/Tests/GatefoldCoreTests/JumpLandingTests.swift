import Testing
@testable import GatefoldCore

/// A web view that accepts a jump before it has loaded: it opens the jump's file at its first page and
/// drops the place inside it, as Readium did on CI's Duo (a jump to 0.993 opened its file's first page,
/// 0.938, while the web view took 27 s to load). Places are within the file; each page spans `span`.
@MainActor
private final class ColdPage {
    let href = "chapter.xhtml"
    let span = 0.05
    let loadsAfterReads: Int?
    var reads = 0
    var start: Double? = nil
    var jumps = 0

    init(loadsAfterReads: Int?) {
        self.loadsAfterReads = loadsAfterReads
    }

    var loaded: Bool { loadsAfterReads.map { reads >= $0 } ?? false }

    /// The start of the page that holds `progression`.
    func pageStart(_ progression: Double) -> Double { (progression / span).rounded(.down) * span }

    func go(_ target: Double) -> Bool {
        jumps += 1
        start = loaded ? pageStart(target) : 0
        return true
    }

    func visible() -> VisibleRange? {
        reads += 1
        return start.map { VisibleRange(href: href, start: $0, end: $0 + span) }
    }

    func place(_ progression: Double) -> ReadingAnchor { ReadingAnchor(href: href, progression: progression, text: nil) }
}

@MainActor
@Suite struct JumpLandingTests {
    @Test func aJumpTakenBeforeThePageLoadedIsSentAgainAndLandsExactly() async {
        let page = ColdPage(loadsAfterReads: 60)
        let landed = await JumpLanding.land(target: page.place(0.62), go: { page.go(0.62) }, visible: { page.visible() }, beat: {})
        #expect(landed)
        #expect(page.start == page.pageStart(0.62))
    }

    @Test func aJumpThatLandsAtOnceIsSentOnce() async {
        let page = ColdPage(loadsAfterReads: 0)
        let landed = await JumpLanding.land(target: page.place(0.62), go: { page.go(0.62) }, visible: { page.visible() }, beat: {})
        #expect(landed)
        #expect(page.jumps == 1)
    }

    @Test func aPageThatNeverLandsEndsWithinItsReads() async {
        let page = ColdPage(loadsAfterReads: nil)
        let landed = await JumpLanding.land(target: page.place(0.62), go: { page.go(0.62) }, visible: { page.visible() }, beat: {})
        #expect(!landed)
        #expect(page.reads <= JumpLanding.reads)
    }

    /// Run 42418233954: a jump to 0.31 counted the chapter's file start, 0.3003, as landed, within the
    /// old 0.015 of the book. Here the target is just past the file's first page, so the file start is
    /// the page right before it, and it is sent again until its own page is up.
    @Test func aFileStartJustShortOfTheTargetIsSentAgain() async {
        let page = ColdPage(loadsAfterReads: 60)
        let landed = await JumpLanding.land(target: page.place(0.051), go: { page.go(0.051) }, visible: { page.visible() }, beat: {})
        #expect(landed)
        #expect(page.start == page.pageStart(0.051))
        #expect(page.jumps > 1)
    }

    /// A target at exactly the file start page's end is the next page's, not the file start's.
    @Test func aTargetAtAPagesEndIsTheNextPages() async {
        let page = ColdPage(loadsAfterReads: nil)
        let landed = await JumpLanding.land(target: page.place(0.05), go: { page.go(0.05) }, visible: { page.visible() }, beat: {})
        #expect(!landed)
    }

    /// A page that can't say where it is (still loading) is never a landing.
    @Test func aPageWithNoRangeIsNotALanding() async {
        let page = ColdPage(loadsAfterReads: 0)
        let landed = await JumpLanding.land(target: page.place(0.02), go: { page.go(0.02) }, visible: { page.reads += 1; return nil }, beat: {})
        #expect(!landed)
        #expect(page.reads == JumpLanding.reads)
    }

    /// A target on its file's first page is on screen at the file's start: it lands at once, even on a
    /// page that never loads further.
    @Test func aTargetOnTheFilesFirstPageLandsAtOnce() async {
        let page = ColdPage(loadsAfterReads: nil)
        let landed = await JumpLanding.land(target: page.place(0.02), go: { page.go(0.02) }, visible: { page.visible() }, beat: {})
        #expect(landed)
        #expect(page.jumps == 1)
        #expect(page.reads == 1)
    }

    /// The right place in another file (the neighbouring chapter) is not a landing.
    @Test func theSamePlaceInAnotherFileIsNotALanding() async {
        let page = ColdPage(loadsAfterReads: 0)
        let elsewhere = ReadingAnchor(href: "other.xhtml", progression: 0.02, text: nil)
        let landed = await JumpLanding.land(target: elsewhere, go: { page.go(0.02) }, visible: { page.visible() }, beat: {})
        #expect(!landed)
    }
}
