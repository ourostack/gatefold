#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GatefoldCore

@Suite struct TapTrackerTests {
    static let here = CGPoint(x: 450, y: 676)

    /// A finger that goes down and lifts at `here`; true when it was a tap.
    static func touch(_ taps: inout TapTracker<Int>, id: Int) -> Bool {
        let down = taps.receive(.down, id: id, at: here)
        let up = taps.receive(.up, id: id, at: here)
        return !down && up
    }

    @Test func aTouchThatLiftsWhereItWentDownIsATap() {
        var taps = TapTracker<Int>()
        #expect(Self.touch(&taps, id: 1))
    }

    @Test func aDragIsNoTap() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 1, at: Self.here)
        _ = taps.receive(.move, id: 1, at: CGPoint(x: 300, y: 676))
        let dragged = taps.receive(.up, id: 1, at: CGPoint(x: 192, y: 676))
        #expect(!dragged)
        // The next touch is a tap again.
        #expect(Self.touch(&taps, id: 2))
    }

    @Test func twoFingersAreNoTap() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 1, at: Self.here)
        _ = taps.receive(.down, id: 2, at: Self.here)
        let first = taps.receive(.up, id: 1, at: Self.here)
        let second = taps.receive(.up, id: 2, at: Self.here)
        #expect(!first && !second)
        #expect(Self.touch(&taps, id: 3))
    }

    /// gatefold#321: the swipe that turned into another chapter went down and never reported lifting.
    /// Without a fresh touch to say so, every tap after it waits on that finger.
    @Test func aSwipeWhosePageWentAwayLeavesItsFingerWaiting() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 188, at: CGPoint(x: 708, y: 676))
        _ = taps.receive(.move, id: 188, at: CGPoint(x: 600, y: 676))
        for id in 193...197 { #expect(!Self.touch(&taps, id: id)) }
    }

    @Test func aFingerAloneOnTheGlassForgetsTheOneThatNeverLifted() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 188, at: CGPoint(x: 708, y: 676))
        _ = taps.receive(.move, id: 188, at: CGPoint(x: 600, y: 676))
        for id in 193...197 {
            taps.aloneOnTheGlass()
            #expect(Self.touch(&taps, id: id))
        }
    }

    /// The glass may say so after the page reported the finger down: the tap still counts.
    @Test func beingAloneOnTheGlassNeverDropsATapUnderWay() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 1, at: Self.here)
        taps.aloneOnTheGlass()
        let up = taps.receive(.up, id: 1, at: Self.here)
        #expect(up)
    }

    /// A finger that went down and never moved nor lifted, its page gone: the next lone finger is a tap at once.
    @Test func aFingerAloneOnTheGlassForgetsOneThatNeverMoved() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 188, at: CGPoint(x: 708, y: 676))
        taps.aloneOnTheGlass()
        #expect(Self.touch(&taps, id: 193))
        // Its lift, heard late, is no tap.
        let late = taps.receive(.up, id: 188, at: CGPoint(x: 708, y: 676))
        #expect(!late)
    }

    /// A second finger down while the first is still on the glass is no tap, as before.
    @Test func aSecondFingerOnTheGlassStillMakesTwo() {
        var taps = TapTracker<Int>()
        taps.aloneOnTheGlass()
        _ = taps.receive(.down, id: 1, at: Self.here)
        _ = taps.receive(.down, id: 2, at: Self.here)
        let first = taps.receive(.up, id: 1, at: Self.here)
        let second = taps.receive(.up, id: 2, at: Self.here)
        #expect(!first && !second)
    }

    @Test func aTouchWithAKeyHeldIsNoTap() {
        var taps = TapTracker<Int>()
        _ = taps.receive(.down, id: 1, at: Self.here, plain: false)
        let up = taps.receive(.up, id: 1, at: Self.here)
        #expect(!up)
        #expect(Self.touch(&taps, id: 2))
    }
}
