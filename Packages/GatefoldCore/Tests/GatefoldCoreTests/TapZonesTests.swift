#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
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

@Suite struct TestPostureSwitchesTests {
    /// Pages the reader lays out: phones, the Duo folded and unfolded, iPads both ways.
    static let pages: [(name: String, frame: CGRect, spread: Bool)] = [
        ("iPhone", CGRect(x: 0, y: 0, width: 402, height: 874), false),
        ("small iPhone", CGRect(x: 0, y: 0, width: 320, height: 568), false),
        ("Duo folded", CGRect(x: 0, y: 0, width: 466, height: 800), false),
        ("Duo unfolded", CGRect(x: 0, y: 0, width: 1100, height: 800), true),
        ("iPad portrait", CGRect(x: 0, y: 0, width: 834, height: 1194), false),
        ("iPad landscape", CGRect(x: 0, y: 0, width: 1376, height: 1032), true),
        ("iPad short spread", CGRect(x: 0, y: 0, width: 1180, height: 820), true),
    ]

    /// No switch is ever in a turn zone, at any height: a test's edge tap or swipe always reaches the page.
    @Test(arguments: pages.map(\.name)) func theSwitchesStayOutOfTheTurnZones(page: String) throws {
        let p = try #require(Self.pages.first { $0.name == page })
        let edge = TapZones.edge(viewWidth: p.frame.width, spread: p.spread)
        let strip = TestPostureSwitches.frame(pageFrame: p.frame, count: Posture.allCases.count)
        #expect(strip.minX >= p.frame.minX + edge, "the switches cover the back-turn zone")
        #expect(strip.maxX <= p.frame.maxX - edge, "the switches cover the forward-turn zone")
        #expect(p.frame.contains(strip), "the switches are off the page")
    }
}
