import Testing
@testable import GatefoldCore

/// A web view that accepts a jump before it has loaded: it opens the jump's file at its first page and
/// drops the place inside it, as Readium did on CI's Duo (a jump to 0.993 opened its file's first page,
/// 0.938, while the web view took 27 s to load).
@MainActor
private final class ColdPage {
    let fileStart: Double
    let loadsAfterReads: Int?
    var reads = 0
    var at: Double? = nil
    var jumps = 0

    init(fileStart: Double, loadsAfterReads: Int?) {
        self.fileStart = fileStart
        self.loadsAfterReads = loadsAfterReads
    }

    var loaded: Bool { loadsAfterReads.map { reads >= $0 } ?? false }

    func go(_ target: Double) -> Bool {
        jumps += 1
        at = loaded ? target : fileStart
        return true
    }

    func reported() -> Double? { reads += 1; return at }
}

@MainActor
@Suite struct JumpLandingTests {
    @Test func aJumpTakenBeforeThePageLoadedIsSentAgainAndLandsExactly() async {
        let page = ColdPage(fileStart: 0.938, loadsAfterReads: 60)
        let landed = await JumpLanding.land(target: 0.993, go: { page.go(0.993) }, reported: { page.reported() }, beat: {})
        #expect(landed)
        #expect(abs((page.at ?? 0) - 0.993) <= JumpLanding.tolerance)
    }

    @Test func aJumpThatLandsAtOnceIsSentOnce() async {
        let page = ColdPage(fileStart: 0.938, loadsAfterReads: 0)
        let landed = await JumpLanding.land(target: 0.993, go: { page.go(0.993) }, reported: { page.reported() }, beat: {})
        #expect(landed)
        #expect(page.jumps == 1)
    }

    @Test func aPageThatNeverLandsEndsWithinItsReads() async {
        let page = ColdPage(fileStart: 0.938, loadsAfterReads: nil)
        let landed = await JumpLanding.land(target: 0.993, go: { page.go(0.993) }, reported: { page.reported() }, beat: {})
        #expect(!landed)
        #expect(page.reads <= JumpLanding.reads)
    }
}
