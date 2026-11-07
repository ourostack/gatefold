import CoreGraphics
import Testing
@testable import GatefoldCore

@Suite struct TapZonesTests {
    @Test func aNarrowPageTurnsOnItsOuterQuarter() {
        #expect(TapZones.edge(viewWidth: 320, spread: false) == 80)
    }

    /// The iPad on its side: 1376 pt across, two pages. The zone is a margin, not half a page's text.
    @Test func anIPadSpreadTurnsOnlyInItsMargins() {
        #expect(TapZones.edge(viewWidth: 1376, spread: true) == 88)
    }

    /// The Duo unfolded: a tap a third of the way across (the left page's middle) is the controls'.
    @Test func aSpreadTurnsOnlyOnEachPagesOuterQuarter() {
        let width: CGFloat = 1100
        let edge = TapZones.edge(viewWidth: width, spread: true)
        #expect(edge == 88)
        #expect(width * 0.3 > edge, "a tap on the left page's middle turns back")
    }
}

@Suite struct ScrubberIntentTests {
    @Test func aTapIsNoJump() {
        #expect(!ScrubberIntent.isDeliberate(translation: .zero))
    }

    @Test func aShortWobbleIsNoJump() {
        #expect(!ScrubberIntent.isDeliberate(translation: CGSize(width: 8, height: 3)))
    }

    @Test func aMostlyVerticalSwipeIsNoJump() {
        #expect(!ScrubberIntent.isDeliberate(translation: CGSize(width: 14, height: 30)))
    }

    @Test func aSidewaysDragIsAJump() {
        #expect(ScrubberIntent.isDeliberate(translation: CGSize(width: -40, height: 4)))
    }
}
