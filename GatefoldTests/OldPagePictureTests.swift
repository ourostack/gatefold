import Testing
@testable import Gatefold

/// gatefold#155: a jump from a page still loading took all ten tries at picturing it (1.7 to 2.7 s on
/// CI's iPad, each one bare) before the jump itself began. A page still loading can't come good in
/// those tries, so the jump starts after one look; and a bare picture is never what the veil holds,
/// so he never sees a blank flash over the jump.
@Suite struct OldPagePictureTests {
    @Test func aPageStillLoadingIsLookedAtOnceAndTheJumpStarts() {
        #expect(OldPagePicture.tries(stillLoading: true) == 1, "a page still loading held the jump back for \(OldPagePicture.tries(stillLoading: true)) looks")
    }

    @Test func aLoadedPageKeepsItsFewTries() {
        // A page that is only briefly bare (a turn settling) comes good within a few tries.
        #expect(OldPagePicture.tries(stillLoading: false) == 10)
    }

    @Test func aBarePictureIsNeverWhatTheVeilHolds() {
        #expect(OldPagePicture.hold(bare: true) == .onScreen, "the veil held a bare picture over the jump")
        #expect(OldPagePicture.hold(bare: false) == .picture)
    }
}

/// gatefold#228: a riffle (a slider jump) from a page still loading curled leaves of its bare picture,
/// a blank page flashing past, the "spazz". A riffle's leaves are pictures of the old page, so a bare
/// one gets none: the veil keeps the screen as it is until the new page is ready, as a plain jump's does.
@Suite struct RiffleLeavesTests {
    @Test func aBarePictureIsNeverCurledAsLeaves() {
        #expect(!OldPagePicture.riffles(OldPagePicture.hold(bare: true)), "a riffle curled leaves of a bare picture")
    }

    @Test func aPictureOfHisPageStillRiffles() {
        #expect(OldPagePicture.riffles(OldPagePicture.hold(bare: false)))
    }
}
