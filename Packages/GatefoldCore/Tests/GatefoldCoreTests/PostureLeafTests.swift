import Testing
@testable import GatefoldCore

/// A change of posture re-lays out the page where it is. Only opening the book from its cover, or shutting it back
/// to the cover, plays a leaf, and only on a page of pages. Half open to flat (tabletop to spread) is the same
/// screen bending, so its page simply re-lays out: a leaf there stood frozen, a grey wedge over a white page, even
/// in scroll mode (Ari, 2026-11-27).
@Suite("The leaf a change of posture plays")
struct PostureLeafTests {
    @Test func openingTheBookFromItsCoverSwingsTheRightPageOpen() {
        #expect(PostureLeaf.plays(from: .single, to: .spread, scrolls: false, hasFold: true) == .unfold)
    }

    @Test func shuttingTheBookToItsCoverFoldsTheRightPageOver() {
        #expect(PostureLeaf.plays(from: .spread, to: .single, scrolls: false, hasFold: true) == .fold)
    }

    @Test func halfOpenToFlatPlaysNoLeaf() {
        #expect(PostureLeaf.plays(from: .tabletop, to: .spread, scrolls: false, hasFold: true) == nil)
        #expect(PostureLeaf.plays(from: .tabletop, to: .spread, scrolls: true, hasFold: true) == nil)
    }

    @Test func flatToHalfOpenPlaysNoLeaf() {
        #expect(PostureLeaf.plays(from: .spread, to: .tabletop, scrolls: false, hasFold: true) == nil)
        #expect(PostureLeaf.plays(from: .spread, to: .tabletop, scrolls: true, hasFold: true) == nil)
    }

    @Test func aScrollingPagePlaysNoLeafForAnyChange() {
        for old in Posture.allCases {
            for new in Posture.allCases {
                #expect(PostureLeaf.plays(from: old, to: new, scrolls: true, hasFold: true) == nil, "\(old) to \(new)")
            }
        }
    }

    @Test func halfOpenAndOnePageTradePlaceWithNoLeaf() {
        #expect(PostureLeaf.plays(from: .single, to: .tabletop, scrolls: false, hasFold: true) == nil)
        #expect(PostureLeaf.plays(from: .tabletop, to: .single, scrolls: false, hasFold: true) == nil)
    }

    @Test func aDeviceWithNoFoldPlaysNoLeaf() {
        #expect(PostureLeaf.plays(from: .single, to: .spread, scrolls: false, hasFold: false) == nil)
        #expect(PostureLeaf.plays(from: .spread, to: .single, scrolls: false, hasFold: false) == nil)
    }
}
