#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GatefoldCore

/// Contents closes on a pull past its list's top, and only when his finger lifts there (build 47).
@Suite struct ContentsPullTests {
    // A list whose top rests at offset -12 (a 12 pt top inset).
    private func closes(_ offset: CGFloat, lifted: Bool = true) -> Bool {
        ContentsPull.closes(fingerLifted: lifted, offset: offset, insetTop: 12)
    }

    @Test func aListAtOrBelowItsTopIsNotStretched() {
        #expect(ContentsPull.stretch(offset: -12, insetTop: 12) == 0)
        #expect(ContentsPull.stretch(offset: 800, insetTop: 12) == 0)
        #expect(ContentsPull.stretch(offset: -52, insetTop: 12) == 40)
    }

    @Test func aPullPastTheTopClosesContentsAsTheFingerLifts() {
        #expect(closes(-12 - ContentsPull.distance))
        #expect(closes(-200))
    }

    @Test func aShortStretchOrAFingerInTheListLeavesItUp() {
        #expect(!closes(-12 - ContentsPull.distance + 1))
        #expect(!closes(-12))
        #expect(!closes(400))
    }

    /// A flick that coasts into the top bounces the list as far, with no finger on it.
    @Test func aCoastIntoTheTopNeverClosesIt() {
        #expect(!closes(-200, lifted: false))
    }
}
