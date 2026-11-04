import Testing
@testable import GatefoldCore

/// The tablet page is laid out like Apple Books' default, measured on Ari's iPad (834 pt tall):
/// the first line at 11 % of the page, the last above 83 %, a 15 pt running head and a 17 pt folio.
@Suite struct TabletPageBandsTests {
    @Test func aTabletPageLeavesAppleBooksBandsAboveAndBelowTheWords() throws {
        let page = try #require(TabletPage.bands(pageHeight: 834))
        // A touch deeper than the 0.105 first tried: the Apple Books review found that top a little shallow.
        #expect(abs(page.top / 834 - 0.115) < 0.005)
        #expect(abs(page.bottom / 834 - 0.15) < 0.005)
        // About 70 % of the page carries words, not build 15's 86 %.
        let fill = (834 - page.top - page.bottom) / 834
        #expect(fill > 0.72 && fill < 0.76)
    }

    @Test func theBandsScaleWithThePage() throws {
        let small = try #require(TabletPage.bands(pageHeight: 834))
        let large = try #require(TabletPage.bands(pageHeight: 1032))
        #expect(abs(small.top / 834 - large.top / 1032) < 0.002)
        #expect(abs(small.bottom / 834 - large.bottom / 1032) < 0.002)
    }

    @Test func theRunningHeadAndFolioAreAppleBooksSized() throws {
        let page = try #require(TabletPage.bands(pageHeight: 834))
        #expect(page.headSize == 15)
        #expect(page.folioSize == 17)
    }

    @Test func aPhonePageKeepsItsOwnMargins() {
        // The folded Duo and iPhones: the page is short, and the review found it comfortable.
        #expect(TabletPage.bands(pageHeight: 0) == nil)
    }
}
