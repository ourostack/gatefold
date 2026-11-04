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
    /// Where a timing curve has the leaf after `t` of its run (0...1): the cubic Bézier SwiftUI uses.
    private static func progress(_ c: CurlTiming.Curve, at t: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let m = (lo + hi) / 2
            let x = 3 * (1 - m) * (1 - m) * m * c.c1x + 3 * (1 - m) * m * m * c.c2x + m * m * m
            if x < t { lo = m } else { hi = m }
        }
        let m = (lo + hi) / 2
        return 3 * (1 - m) * (1 - m) * m * c.c1y + 3 * (1 - m) * m * m * c.c2y + m * m * m
    }

    /// Milliseconds the leaf spends covering its last `points` of a `travel`-point flight.
    private static func creep(_ c: CurlTiming.Curve, travel: Double, last points: Double) -> Double {
        let t = (0...1000).first { travel * (1 - progress(c, at: Double($0) / 1000)) <= points }.map { Double($0) / 1000 } ?? 1
        return (1 - t) * c.duration * 1000
    }

    /// The spread's leaf lands on the outer corner and stops: it doesn't creep the last stretch over
    /// many frames (build 15 spent 144 ms on its last 42 pt, which a burst saw as an inward drift).
    @Test func aSpreadLeafLandsWithoutCreepingIntoPlace() {
        let landing = CurlTiming.landing(isSpread: true)
        #expect(Self.creep(landing, travel: 688, last: 42) < 60, "the last 42 pt take \(Self.creep(landing, travel: 688, last: 42)) ms")
        #expect(Self.creep(landing, travel: 688, last: 5) < 20)
        // Still a turn, not a snap: half-way no sooner than a fifth of a second in.
        #expect(Self.progress(landing, at: 0.2 / landing.duration) < 0.5)
    }

    @Test func aSinglePageLeafKeepsItsTurn() {
        let single = CurlTiming.landing(isSpread: false)
        #expect(single == CurlTiming.Curve(c1x: 0.3, c1y: 0.1, c2x: 0.25, c2y: 1, duration: 0.48))
    }
}
