import Testing
@testable import GatefoldCore

/// Invented words, not a book's: what the turn round in RotationRepro judges.
struct ReopenMatchTests {
    // A spread that opens on "ord", the tail of "w-ord" hyphenated across the turn.
    let leftOnTail = "ord rests upon the hill beside the old mill and the river runs below it"
    let reopenedFromWhole = "rests upon the hill beside the old mill and the river runs below it all day"
    // A spread that opens on the whole word "Stone".
    let leftOnWhole = "Stone rests upon the hill beside the old mill and the river runs below it"

    @Test func theSameHeadIsTheSameSpread() {
        #expect(ReopenMatch.compare(left: leftOnWhole, reopened: leftOnWhole + " more", saved: leftOnWhole) == .exact)
    }

    /// 4652719's turn round: the place saved was the first whole word, and the reopen starts there.
    @Test func aWordsTailDroppedIsHisPageWhenTheSavedPlaceSkippedIt() {
        #expect(ReopenMatch.compare(left: leftOnTail, reopened: reopenedFromWhole,
                                    saved: "rests upon the hill beside the old mill and the") == .fromSavedWholeWord)
    }

    /// A page that opened on a whole word and reopened one word later skipped his place.
    @Test func aWholeWordDroppedIsAForwardSkip() {
        #expect(ReopenMatch.compare(left: leftOnWhole, reopened: reopenedFromWhole,
                                    saved: "Stone rests upon the hill beside the old mill and") == .different)
    }

    @Test func withNoSavedPlaceOnlyAnExactReopenCounts() {
        #expect(ReopenMatch.compare(left: leftOnTail, reopened: reopenedFromWhole, saved: nil) == .different)
        #expect(ReopenMatch.compare(left: leftOnTail, reopened: reopenedFromWhole, saved: "") == .different)
    }

    /// The saved place agrees with the dropped token, but the reopen went further still.
    @Test func aReopenPastTheSavedPlaceIsDifferent() {
        #expect(ReopenMatch.compare(left: leftOnTail, reopened: "upon the hill beside the old mill and the river",
                                    saved: "rests upon the hill beside the old mill and the") == .different)
    }
}
