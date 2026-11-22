import GatefoldCore
import Testing
import UIKit
@testable import Gatefold

/// A look that isn't about the margins keeps the margins the page was laid out with. On the folded Duo the book
/// opens with margins worked out for the placeholder width (402 pt), within the same step as the cover screen's 466,
/// so they stay (gatefold#302). Each later look worked them out afresh for 466, so a change of Justify or of the
/// paper cut the book into new pages and his words came back 9 to 62 words down the page (build 47's Duo run);
/// a change of paper has no restore at all.
@MainActor
struct KeptMarginsTests {
    private func basis(_ choice: PageMargins = .normal, columns: GatefoldCore.ColumnCount = .one, tabletop: Bool = false,
                       width: CGFloat) -> ReaderModel.MarginsBasis {
        ReaderModel.MarginsBasis(choice: choice, columns: columns, tabletop: tabletop,
                                 band: ReaderModel.marginBand(columns: columns, viewWidth: width))
    }

    @Test func theOpeningsMarginsStayWhileNothingTheyComeFromHasChanged() {
        let opened = ReaderModel.epubPreferences(ReaderPreferences(), theme: .daylight, columns: .one, viewWidth: 402).pageMargins
        let fresh = ReaderModel.epubPreferences(ReaderPreferences(), theme: .sage, columns: .one, viewWidth: 466).pageMargins
        // The premise: the same step, and different margins worked out for each width.
        #expect(basis(width: 402) == basis(width: 466))
        #expect(opened != fresh)
        #expect(ReaderModel.pageMargins(fresh: fresh, applied: opened, laidFor: basis(width: 402), now: basis(width: 466)) == opened)
    }

    @Test func hisMarginsChoiceWorksThemOutAfresh() {
        #expect(ReaderModel.pageMargins(fresh: 1.4, applied: 1.1, laidFor: basis(width: 466), now: basis(.wide, width: 466)) == 1.4)
    }

    @Test func newColumnsTabletopOrAnotherStepWorkThemOutAfresh() {
        let was = basis(width: 1032)
        #expect(ReaderModel.pageMargins(fresh: 1.4, applied: 1.1, laidFor: was, now: basis(columns: .two, width: 1032)) == 1.4)
        #expect(ReaderModel.pageMargins(fresh: 1.4, applied: 1.1, laidFor: was, now: basis(tabletop: true, width: 1032)) == 1.4)
        #expect(ReaderModel.pageMargins(fresh: 1.4, applied: 1.1, laidFor: basis(width: 402), now: basis(width: 1032)) == 1.4)
    }

    @Test func aPageNeverLaidOutTakesThemFresh() {
        #expect(ReaderModel.pageMargins(fresh: 1.4, applied: nil, laidFor: nil, now: basis(width: 466)) == 1.4)
    }
}

/// Justify Off sets the text ragged rather than leaving the book's own alignment, which for a Gutenberg book is
/// justified: the switch read Off over a justified page (review panel 2026-11-22).
@MainActor
struct JustifyAlignmentTests {
    @Test func offSetsTheTextRaggedAndOnJustifiesIt() {
        var prefs = ReaderPreferences()
        prefs.justify = false
        #expect(ReaderModel.epubPreferences(prefs, theme: .daylight, columns: .one, viewWidth: 466).textAlign == .start)
        prefs.justify = true
        #expect(ReaderModel.epubPreferences(prefs, theme: .daylight, columns: .one, viewWidth: 466).textAlign == .justify)
    }
}
