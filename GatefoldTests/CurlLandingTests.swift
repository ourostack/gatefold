import CoreGraphics
import Testing
@testable import Gatefold

/// A spread's turned leaf lands exactly on the other page, flat, so the page beneath and the leaf's
/// back are one picture when the overlay lifts (build 14 landed it a roll's length toward the outer
/// edge, then jumped back).
@MainActor
struct CurlLandingTests {
    private func spread(mirrored: Bool) -> CurlModel {
        let m = CurlModel()
        m.size = CGSize(width: 1376, height: 1032)
        m.isSpread = true
        m.mirrored = mirrored
        m.corner = CGPoint(x: mirrored ? 0 : 1376, y: 1032)
        m.finger = m.corner
        return m
    }

    @Test func aSpreadLeafLandsOnTheOuterCornerOfTheOtherPage() {
        let m = spread(mirrored: false)
        // The leaf's back sits at x + (2·spine − width − finger): zero offset only at the reflected corner.
        #expect(m.turnedFinger.x == 0)
        #expect(m.turnedFinger.y == m.corner.y)
    }

    @Test func aSpreadLeafRollsWhileItTurnsAndLiesFlatAsItLands() {
        let m = spread(mirrored: false)
        #expect(m.radius >= 18, "lifting, the leaf rolls")
        m.finger = CGPoint(x: 688, y: 1032)
        #expect(m.radius >= 18, "halfway, still a full roll")
        m.finger = m.turnedFinger
        #expect(m.radius <= 1, "landed, the leaf is flat")
    }

    @Test func turningBackMirrorsTheLanding() {
        let m = spread(mirrored: true)
        m.finger = CGPoint(x: m.size.width - m.turnedFinger.x, y: m.corner.y)
        #expect(m.radius <= 1)
    }

    @Test func aSinglePageLeafStillLeavesTheScreen() {
        let m = CurlModel()
        m.size = CGSize(width: 466, height: 600)
        #expect(m.turnedFinger.x < -466)
        #expect(m.radius >= 18)
    }
}
