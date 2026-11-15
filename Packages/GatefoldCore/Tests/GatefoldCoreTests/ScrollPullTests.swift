#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GatefoldCore

/// Scroll mode turns a chapter only on a drag on past its end or back past its start (Ari, build 39).
@Suite struct ScrollPullTests {
    // A 600 pt screen with 28 pt insets top and bottom, over a 3000 pt chapter: the top is at -28, the end at 2428.
    private func edge(_ offset: CGFloat, content: CGFloat = 3000) -> ScrollPull.Edge? {
        ScrollPull.edge(offset: offset, viewport: 600, content: content, insetTop: 28, insetBottom: 28)
    }

    @Test func theMiddleOfAChapterIsNoEdge() {
        #expect(edge(1200) == nil)
    }

    @Test func theTopAndTheEndAreEdges() {
        #expect(edge(-28) == .start)
        #expect(edge(-27) == .start)
        #expect(edge(2428) == .end)
        #expect(edge(2427) == .end)
        #expect(edge(2400) == nil)
    }

    @Test func aChapterShorterThanTheScreenIsBothEdges() {
        #expect(edge(-28, content: 300) == .both)
    }

    @Test func onPastTheEndTurnsForward() {
        #expect(ScrollPull.turn(from: .end, dragged: CGPoint(x: 0, y: -ScrollPull.distance - 1)) == true)
        #expect(ScrollPull.turn(from: .both, dragged: CGPoint(x: 0, y: -ScrollPull.distance - 1)) == true)
    }

    @Test func backPastTheStartTurnsBack() {
        #expect(ScrollPull.turn(from: .start, dragged: CGPoint(x: 0, y: ScrollPull.distance + 1)) == false)
        #expect(ScrollPull.turn(from: .both, dragged: CGPoint(x: 0, y: ScrollPull.distance + 1)) == false)
    }

    @Test func aShortDragOrTheWrongWayNeverTurns() {
        #expect(ScrollPull.turn(from: .end, dragged: CGPoint(x: 0, y: -ScrollPull.distance + 10)) == nil)
        #expect(ScrollPull.turn(from: .end, dragged: CGPoint(x: 0, y: 200)) == nil)
        #expect(ScrollPull.turn(from: .start, dragged: CGPoint(x: 0, y: -200)) == nil)
    }

    /// A sideways swipe at a chapter's end, however long, is no pull (his first report).
    @Test func aSidewaysSwipeNeverTurns() {
        #expect(ScrollPull.turn(from: .end, dragged: CGPoint(x: -300, y: -90)) == nil)
        #expect(ScrollPull.turn(from: .start, dragged: CGPoint(x: 300, y: 90)) == nil)
    }
}
